#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# destroy-all.sh — Wave-based teardown of the AI-Ops PoC across 3 accounts
#
# Deletes all PoC CloudFormation stacks directly via the CloudFormation API
# (no CDK app synthesis needed), in dependency-safe waves. Within a wave all
# deletes are launched in parallel, then the script waits on all of them.
#
#   Wave 1 (parallel):
#     OPS: AgentSpacesStack           — Agent Spaces + associations/webhook
#     OPS: AgentsInfraStack           — AgentCore runtimes, KB, webhook bridge
#     FE:  FrontendAgentRoleStack     — DevOps Agent monitor role
#     FE:  FrontendStack              — petsite, canary, PrivateLink endpoint
#     BE:  BackendAgentRoleStack      — DevOps Agent monitor role
#   Wave 2:
#     BE:  BackendOverlayStack        — endpoint service (needs FE endpoint gone)
#   Wave 3a (parallel):
#     BE:  aiops-poc-upstream-backend — CodeBuild deployer stack
#     BE:  DevApplicationsStack       — upstream PetAdoptions applications
#     BE:  DevComputeStack            — upstream ECS/EKS compute (slow)
#   Wave 3b:
#     BE:  DevCoreStack               — upstream VPC/core (children must be gone)
#
# Safety:
#   - NEVER touches CDKToolkit / CDKToolkitDefault bootstrap stacks or their
#     bootstrap S3/ECR assets.
#   - Only deletes the explicit stack names above.
#   - S3 buckets owned by a stack are emptied (all versions + delete markers)
#     before the stack delete so deletion does not hang.
#   - On DELETE_FAILED: diagnoses the blocking resources, re-empties buckets,
#     and retries the delete once.
#
# Post-stack cleanup:
#   - OPS Secrets Manager secret aiops-poc/webhook-credentials (force delete,
#     recreated by register-webhook.sh on redeploy)
#   - Script-created SSM parameters under /aiops-poc and /petstore in all
#     three accounts
#
# Usage:
#   scripts/destroy-all.sh --confirm [--help]
#
# Flags:
#   --confirm   Required safety flag — refuses to run without it
#   -h, --help  Show this help
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Every account, region and profile below comes from the Config_Resolver — the
# one shared location that reads config/accounts.json (Requirement 2.6).
source "${PROJECT_ROOT}/scripts/lib/config.sh"

# ─── Parse flags ─────────────────────────────────────────────────────────────
CONFIRMED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRMED=true; shift ;;
    -h|--help)
      echo "Usage: scripts/destroy-all.sh --confirm"
      echo ""
      echo "Tears down all PoC stacks in dependency-safe waves."
      echo ""
      echo "Flags:"
      echo "  --confirm   Required — refuses to run without this flag"
      echo "  -h, --help  Show this help"
      echo ""
      echo "WARNING: This destroys all deployed PoC resources across all three accounts."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$CONFIRMED" != "true" ]]; then
  echo "ERROR: This script destroys all PoC resources across 3 accounts." >&2
  echo "" >&2
  echo "If you are sure, run with --confirm:" >&2
  echo "  scripts/destroy-all.sh --confirm" >&2
  exit 1
fi

# ─── Validate ────────────────────────────────────────────────────────────────
# config::init checks jq and the config file itself, naming the missing
# prerequisite or the file to create (Requirements 3.1, 3.4).
config::init

# ─── Read config ─────────────────────────────────────────────────────────────
# One call per role sets CONFIG_<ROLE>_{ACCOUNT,REGION,PROFILE}.
config::account be
config::account fe
config::account ops

BE_PROFILE="$CONFIG_BE_PROFILE"
FE_PROFILE="$CONFIG_FE_PROFILE"
OPS_PROFILE="$CONFIG_OPS_PROFILE"
REGION="$CONFIG_BE_REGION"

# ─── Result tracking ────────────────────────────────────────────────────────
RESULTS_FILE=$(mktemp)
trap 'rm -f "$RESULTS_FILE"' EXIT
record_result() { # profile stack status
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS_FILE"
}

# ─── Helpers ─────────────────────────────────────────────────────────────────
banner() {
  echo ""
  echo "╔═══════════════════════════════════════════════════════════════════╗"
  echo "║  $1"
  echo "╚═══════════════════════════════════════════════════════════════════╝"
  echo ""
}

# Guardrail: refuse to operate on bootstrap stacks or bootstrap assets.
assert_not_protected() {
  local name="$1"
  case "$name" in
    CDKToolkit*|cdk-*assets*|cdk-*container-assets*)
      echo "FATAL: refusing to touch protected resource: $name" >&2
      exit 99
      ;;
  esac
}

stack_status() { # profile stack -> status or "ABSENT"
  aws cloudformation describe-stacks --stack-name "$2" \
    --profile "$1" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "ABSENT"
}

# Empty an S3 bucket completely: all object versions + delete markers.
empty_bucket() { # profile bucket
  local profile="$1" bucket="$2"
  assert_not_protected "$bucket"
  if ! aws s3api head-bucket --bucket "$bucket" --profile "$profile" --region "$REGION" 2>/dev/null; then
    return 0
  fi
  echo "    Emptying s3://${bucket} ..."
  local batch count
  while :; do
    batch=$(aws s3api list-object-versions --bucket "$bucket" \
      --profile "$profile" --region "$REGION" --max-items 500 --output json 2>/dev/null \
      | jq -c '{Objects: (((.Versions // []) + (.DeleteMarkers // [])) | map({Key: .Key, VersionId: .VersionId})), Quiet: true}')
    count=$(echo "$batch" | jq '.Objects | length')
    [[ "$count" -eq 0 ]] && break
    echo "$batch" | aws s3api delete-objects --bucket "$bucket" \
      --profile "$profile" --region "$REGION" --delete file:///dev/stdin > /dev/null
    echo "      deleted ${count} object versions"
  done
}

# Empty every AWS::S3::Bucket resource owned by a stack.
empty_stack_buckets() { # profile stack
  local profile="$1" stack="$2" buckets b
  buckets=$(aws cloudformation list-stack-resources --stack-name "$stack" \
    --profile "$profile" --region "$REGION" \
    --query "StackResourceSummaries[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
    --output text 2>/dev/null || true)
  for b in $buckets; do
    [[ "$b" == "None" ]] && continue
    empty_bucket "$profile" "$b"
  done
}

# Best-effort cleanup of S3 Vectors buckets/indexes (agents-infra KB storage).
cleanup_s3vectors() { # profile
  local profile="$1" vb idx
  local vbuckets
  vbuckets=$(aws s3vectors list-vector-buckets --profile "$profile" --region "$REGION" \
    --query 'vectorBuckets[].vectorBucketName' --output text 2>/dev/null || true)
  for vb in $vbuckets; do
    [[ "$vb" == "None" || -z "$vb" ]] && continue
    case "$vb" in
      *aiops*|*agents*|*kb*)
        echo "    Cleaning S3 Vectors bucket: $vb"
        local idxs
        idxs=$(aws s3vectors list-indexes --vector-bucket-name "$vb" \
          --profile "$profile" --region "$REGION" \
          --query 'indexes[].indexName' --output text 2>/dev/null || true)
        for idx in $idxs; do
          [[ "$idx" == "None" || -z "$idx" ]] && continue
          aws s3vectors delete-index --vector-bucket-name "$vb" --index-name "$idx" \
            --profile "$profile" --region "$REGION" 2>/dev/null || true
        done
        aws s3vectors delete-vector-bucket --vector-bucket-name "$vb" \
          --profile "$profile" --region "$REGION" 2>/dev/null || true
        ;;
    esac
  done
}

# Launch a stack delete (non-blocking). Prints nothing if the stack is absent.
start_delete() { # profile stack
  local profile="$1" stack="$2" status
  assert_not_protected "$stack"
  status=$(stack_status "$profile" "$stack")
  if [[ "$status" == "ABSENT" ]]; then
    echo "  [$profile] $stack: not present, skipping."
    record_result "$profile" "$stack" "ABSENT"
    return 0
  fi
  if [[ "$status" != "DELETE_IN_PROGRESS" ]]; then
    empty_stack_buckets "$profile" "$stack"
  fi
  echo "  [$profile] $stack: delete initiated (was $status)"
  aws cloudformation delete-stack --stack-name "$stack" \
    --profile "$profile" --region "$REGION"
}

# Wait for a stack to finish deleting. On DELETE_FAILED, diagnose, clean
# blockers (buckets, s3 vectors), and retry the delete once.
# timeout_min defaults to 60.
wait_delete() { # profile stack [timeout_min]
  local profile="$1" stack="$2" timeout_min="${3:-60}"
  local deadline=$(( $(date +%s) + timeout_min * 60 ))
  local status retried=false

  # Skip waiting if never present
  if grep -q "^${profile}	${stack}	ABSENT$" "$RESULTS_FILE" 2>/dev/null; then
    return 0
  fi

  while :; do
    status=$(stack_status "$profile" "$stack")
    case "$status" in
      ABSENT|DELETE_COMPLETE)
        echo "  [$profile] $stack: DELETE_COMPLETE"
        record_result "$profile" "$stack" "DELETE_COMPLETE"
        return 0
        ;;
      DELETE_FAILED)
        echo "  [$profile] $stack: DELETE_FAILED — diagnosing..."
        aws cloudformation describe-stack-events --stack-name "$stack" \
          --profile "$profile" --region "$REGION" \
          --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceType,ResourceStatusReason]" \
          --output text | head -20 || true
        if [[ "$retried" == "true" ]]; then
          echo "  [$profile] $stack: still DELETE_FAILED after retry. Manual attention needed."
          record_result "$profile" "$stack" "DELETE_FAILED"
          return 1
        fi
        retried=true
        empty_stack_buckets "$profile" "$stack"
        if [[ "$stack" == "AgentsInfraStack" ]]; then
          cleanup_s3vectors "$profile"
        fi
        echo "  [$profile] $stack: retrying delete..."
        aws cloudformation delete-stack --stack-name "$stack" \
          --profile "$profile" --region "$REGION"
        ;;
      DELETE_IN_PROGRESS)
        : # keep polling
        ;;
      *)
        echo "  [$profile] $stack: unexpected status $status, continuing to poll..."
        ;;
    esac
    if (( $(date +%s) > deadline )); then
      echo "  [$profile] $stack: TIMEOUT after ${timeout_min} min (status: $status)"
      record_result "$profile" "$stack" "TIMEOUT_${status}"
      return 1
    fi
    sleep 30
  done
}

# ─── Execute ─────────────────────────────────────────────────────────────────
START_TS=$(date +%s)
banner "AI-Ops PoC — Full Teardown (DESTRUCTIVE)"
echo "  Config: ${CONFIG_FILE_PATH}"
echo "  Region: ${REGION}"
echo ""
echo "  BE:  ${CONFIG_BE_ACCOUNT}  (profile: ${BE_PROFILE})"
echo "  FE:  ${CONFIG_FE_ACCOUNT}  (profile: ${FE_PROFILE})"
echo "  OPS: ${CONFIG_OPS_ACCOUNT}  (profile: ${OPS_PROFILE})"
echo ""
echo "  Starting in 5 seconds... (Ctrl+C to abort)"
sleep 5

WAVE_FAILURES=0

# ─── Wave 1 ──────────────────────────────────────────────────────────────────
banner "Wave 1: OPS agent stacks + FE stacks + BE agent role (parallel)"
start_delete "$OPS_PROFILE" "AgentSpacesStack"
start_delete "$OPS_PROFILE" "AgentsInfraStack"
start_delete "$FE_PROFILE"  "FrontendAgentRoleStack"
start_delete "$FE_PROFILE"  "FrontendStack"
start_delete "$BE_PROFILE"  "BackendAgentRoleStack"

echo ""
echo ">>> Waiting on Wave 1 deletions..."
wait_delete "$OPS_PROFILE" "AgentSpacesStack" 30 || WAVE_FAILURES=$((WAVE_FAILURES+1))
wait_delete "$OPS_PROFILE" "AgentsInfraStack" 45 || WAVE_FAILURES=$((WAVE_FAILURES+1))
wait_delete "$FE_PROFILE"  "FrontendAgentRoleStack" 20 || WAVE_FAILURES=$((WAVE_FAILURES+1))
wait_delete "$FE_PROFILE"  "FrontendStack" 45 || WAVE_FAILURES=$((WAVE_FAILURES+1))
wait_delete "$BE_PROFILE"  "BackendAgentRoleStack" 20 || WAVE_FAILURES=$((WAVE_FAILURES+1))

# ─── Wave 2 ──────────────────────────────────────────────────────────────────
banner "Wave 2: BE BackendOverlayStack (endpoint service)"
start_delete "$BE_PROFILE" "BackendOverlayStack"
wait_delete "$BE_PROFILE" "BackendOverlayStack" 30 || WAVE_FAILURES=$((WAVE_FAILURES+1))

# ─── Wave 3a ─────────────────────────────────────────────────────────────────
banner "Wave 3a: BE upstream children + CodeBuild deployer (parallel, slow)"
start_delete "$BE_PROFILE" "aiops-poc-upstream-backend"
start_delete "$BE_PROFILE" "DevApplicationsStack"
start_delete "$BE_PROFILE" "DevComputeStack"

echo ""
echo ">>> Waiting on Wave 3a deletions (EKS/ECS teardown is slow)..."
wait_delete "$BE_PROFILE" "aiops-poc-upstream-backend" 30 || WAVE_FAILURES=$((WAVE_FAILURES+1))
wait_delete "$BE_PROFILE" "DevApplicationsStack" 60 || WAVE_FAILURES=$((WAVE_FAILURES+1))
wait_delete "$BE_PROFILE" "DevComputeStack" 120 || WAVE_FAILURES=$((WAVE_FAILURES+1))

# ─── Wave 3b ─────────────────────────────────────────────────────────────────
banner "Wave 3b: BE DevCoreStack (VPC/core, after children)"
start_delete "$BE_PROFILE" "DevCoreStack"
wait_delete "$BE_PROFILE" "DevCoreStack" 90 || WAVE_FAILURES=$((WAVE_FAILURES+1))

# ─── Non-CFN cleanup ─────────────────────────────────────────────────────────
banner "Post-stack cleanup: secrets + script-created SSM parameters"

echo ">>> Deleting OPS webhook secret (recreated by register-webhook.sh on redeploy)..."
aws secretsmanager delete-secret \
  --secret-id "aiops-poc/webhook-credentials" \
  --force-delete-without-recovery \
  --profile "$OPS_PROFILE" --region "$REGION" > /dev/null 2>&1 \
  && echo "    deleted: aiops-poc/webhook-credentials" \
  || echo "    not present: aiops-poc/webhook-credentials"

cleanup_ssm_path() { # profile path
  local profile="$1" path="$2" names
  names=$(aws ssm get-parameters-by-path --path "$path" --recursive \
    --profile "$profile" --region "$REGION" \
    --query 'Parameters[].Name' --output text 2>/dev/null || true)
  if [[ -z "$names" || "$names" == "None" ]]; then
    echo "    [$profile] no parameters under $path"
    return 0
  fi
  # delete-parameters accepts max 10 names per call
  echo "$names" | tr '\t' '\n' | sed "s|^|    [$profile] deleting: |"
  echo "$names" | tr '\t' '\n' \
    | xargs -n 10 aws ssm delete-parameters \
        --profile "$profile" --region "$REGION" --names > /dev/null
}

for prof in "$BE_PROFILE" "$FE_PROFILE" "$OPS_PROFILE"; do
  echo ">>> Cleaning SSM parameters in profile: $prof"
  cleanup_ssm_path "$prof" "/aiops-poc"
  cleanup_ssm_path "$prof" "/petstore"
done

# ─── Final verification ──────────────────────────────────────────────────────
banner "Verification: remaining stacks per account"
for prof in "$BE_PROFILE" "$FE_PROFILE" "$OPS_PROFILE"; do
  echo ">>> [$prof] remaining stacks:"
  aws cloudformation describe-stacks --profile "$prof" --region "$REGION" \
    --query 'Stacks[].[StackName,StackStatus]' --output text | sort | sed 's/^/    /'
  echo ""
done

# ─── Summary ─────────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - START_TS ))
banner "Teardown summary"
printf '  %-15s %-35s %s\n' "PROFILE" "STACK" "RESULT"
printf '  %-15s %-35s %s\n' "-------" "-----" "------"
# Show the LAST recorded result per stack
awk -F'\t' '{ key=$1 FS $2; last[key]=$3 } END { for (k in last) { split(k, a, FS); printf "  %-15s %-35s %s\n", a[1], a[2], last[k] } }' "$RESULTS_FILE" | sort

echo ""
echo "  Total duration: $((ELAPSED / 60))m $((ELAPSED % 60))s"
echo "  Wave failures:  ${WAVE_FAILURES}"
echo ""
if [[ "$WAVE_FAILURES" -gt 0 ]]; then
  echo "  Some stacks need manual attention (see DELETE_FAILED/TIMEOUT above)."
  exit 1
fi
echo "  All PoC stacks removed. Accounts are ready for scripts/deploy-all.sh."
