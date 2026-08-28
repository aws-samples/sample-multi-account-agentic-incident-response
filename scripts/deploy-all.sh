#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-all.sh — Full ordered deployment of the AI-Ops PoC across 3 accounts
#
# Deploys in the exact order specified by the design's cross-account wiring
# plan, stopping on any error:
#
#   1. Upstream backend (BE)
#   2. Backend overlay (BE) — creates the PrivateLink endpoint service
#   3. Frontend workload (FE) — first syncs the PrivateLink service name
#      (BE → FE SSM), then deploys the FE stack, which creates the interface
#      endpoint and writes the /petstore/ search + petlistadoptions URLs
#   4. Agents/infra (OPS)
#   5. Agent Spaces phase 1 (OPS) — spaces only, no associations
#   6. Sync outputs — space ARNs + task-role ARNs + petsite API GW URLs
#   7. Agent-role stacks (FE + BE)
#   8. Agent Spaces phase 2 (OPS) — associations enabled
#   9. Skills packaging (the upload + capability-provider commands are printed)
#  10. Restart petsite ECS service (pick up final /petstore params)
#
# Usage:
#   scripts/deploy-all.sh [--skip-upstream] [--start-from <step>]
#                         [--skip-preflight] [--help]
#
# Flags:
#   --skip-upstream   Skip step 1 if upstream is already deployed
#   --start-from N    Resume from step N (1-10)
#   --skip-preflight  Do not run scripts/preflight.sh first (see below)
#   -h, --help        Show this help
#
# Requirements: 15.1, 15.3, 9.3
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Every profile and region below comes from the Config_Resolver — the one
# shared location that reads config/accounts.json (Requirement 2.6).
source "${PROJECT_ROOT}/scripts/lib/config.sh"

# ─── Parse flags ─────────────────────────────────────────────────────────────
SKIP_UPSTREAM=false
START_FROM=1
SKIP_PREFLIGHT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-upstream) SKIP_UPSTREAM=true; shift ;;
    --start-from)   START_FROM="$2"; shift 2 ;;
    --skip-preflight) SKIP_PREFLIGHT=true; shift ;;
    -h|--help)
      echo "Usage: scripts/deploy-all.sh [--skip-upstream] [--start-from <step>] [--skip-preflight]"
      echo ""
      echo "Deploys all PoC stacks in the correct cross-account order."
      echo ""
      echo "Steps:"
      echo "  1. Upstream backend (BE)          — CodeBuild CDK deploy"
      echo "  2. Backend overlay (BE)           — SLO alarms, SNS, read role, FIS, PrivateLink svc"
      echo "  3. Frontend workload (FE)         — sync PrivateLink name, then petsite, canary, SLO alarm"
      echo "  4. Agents/infra (OPS)             — AgentCore runtimes, KB, webhook bridge"
      echo "  5. Agent Spaces phase 1 (OPS)     — spaces only"
      echo "  6. Sync outputs                   — cross-account SSM parameters"
      echo "  7. Agent-role stacks (FE + BE)    — DevOps Agent monitor roles"
      echo "  8. Agent Spaces phase 2 (OPS)     — associations enabled"
      echo "  9. Skills packaging                — package-skills; upload + registration printed"
      echo " 10. Restart petsite (FE)           — force-new-deployment to load final params"
      echo ""
      echo "Flags:"
      echo "  --skip-upstream   Skip step 1 (upstream already deployed)"
      echo "  --start-from N    Resume from step N (1-10)"
      echo "  --skip-preflight  Skip scripts/preflight.sh (parameter/config gate)"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Validate ────────────────────────────────────────────────────────────────
# config::init checks jq and the config file itself, naming the missing
# prerequisite or the file to create (Requirements 3.1, 3.4).
config::init

# ─── Preflight (Requirement 9.3) ─────────────────────────────────────────────
# Runs before the first AWS call — the first one is step 1's deploy-upstream.sh
# — so an unset account ID, a value still holding a placeholder, a region split
# across the three accounts, or a stale cdk.context.json cache fails here
# instead of in the middle of a ten-step, multi-account deployment. preflight.sh
# makes no AWS calls of its own, so this costs nothing and needs no credentials.
#
# --skip-preflight is a deliberate escape hatch. The gate is static tooling in
# front of an operator's own accounts, and a Replicator who knows more than a
# static check — resuming with --start-from after fixing something by hand, or a
# check that is itself broken mid-refactor — must never be locked out of
# deploying. It is opt-in and announces itself rather than being the default.
if [[ "$SKIP_PREFLIGHT" == "true" ]]; then
  echo ">>> Skipping preflight checks (--skip-preflight)."
  echo ""
elif [[ -x "${SCRIPT_DIR}/preflight.sh" ]]; then
  echo ">>> Preflight checks (read-only, no AWS calls)..."
  if ! "${SCRIPT_DIR}/preflight.sh" --quiet; then
    echo "" >&2
    echo "ERROR: preflight failed — nothing was deployed. Fix the problems above," >&2
    echo "       or re-run with --skip-preflight to proceed anyway." >&2
    exit 1
  fi
  echo ""
fi

# ─── Read config ─────────────────────────────────────────────────────────────
# One call per role sets CONFIG_<ROLE>_{ACCOUNT,REGION,PROFILE}.
config::account be
config::account fe
config::account ops

BE_PROFILE="$CONFIG_BE_PROFILE"
FE_PROFILE="$CONFIG_FE_PROFILE"
FE_REGION="$CONFIG_FE_REGION"
OPS_PROFILE="$CONFIG_OPS_PROFILE"

# ─── Helpers ─────────────────────────────────────────────────────────────────
STEP_COUNT=0

step() {
  local step_num="$1"
  local description="$2"
  ((STEP_COUNT++)) || true
  echo ""
  echo "╔═══════════════════════════════════════════════════════════════════╗"
  echo "║  Step ${step_num}: ${description}"
  echo "╚═══════════════════════════════════════════════════════════════════╝"
  echo ""
}

check_exit() {
  local step_num="$1"
  local exit_code="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    echo ""
    echo "ERROR: Step ${step_num} failed with exit code ${exit_code}. Stopping." >&2
    exit "$exit_code"
  fi
}

# ─── Execute ─────────────────────────────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  AI-Ops PoC — Full Deployment                                    ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Config:         ${CONFIG_FILE_PATH}"
echo "  Skip upstream:  ${SKIP_UPSTREAM}"
echo "  Start from:     step ${START_FROM}"
echo ""

# ─── Step 1: Upstream backend (BE) ───────────────────────────────────────────
if [[ "$START_FROM" -le 1 ]]; then
  if [[ "$SKIP_UPSTREAM" == "true" ]]; then
    echo ">>> Skipping step 1 (upstream backend) — --skip-upstream flag set"
  else
    step 1 "Upstream backend (BE)"
    "${PROJECT_ROOT}/workload/backend/deploy/deploy-upstream.sh" --wait
    check_exit 1 $?
  fi
fi

# ─── Step 2: Backend overlay (BE) ───────────────────────────────────────────
if [[ "$START_FROM" -le 2 ]]; then
  step 2 "Backend overlay (BE)"
  # The overlay looks up the upstream VPC (Vpc.fromLookup), which CDK caches
  # in cdk.context.json. After a teardown/redeploy the upstream stack creates
  # a NEW VPC with new subnet IDs, so a stale cached lookup would reference
  # deleted resources. Reset the cached VPC lookup so CDK re-resolves fresh.
  BE_CONTEXT_FILE="${PROJECT_ROOT}/workload/backend/overlay/cdk.context.json"
  if [[ -f "$BE_CONTEXT_FILE" ]]; then
    echo ">>> Resetting cached upstream VPC context lookup (avoid stale VPC/subnet IDs)..."
    jq 'with_entries(select(.key | startswith("vpc-provider:") | not))' \
      "$BE_CONTEXT_FILE" > "${BE_CONTEXT_FILE}.tmp" && mv "${BE_CONTEXT_FILE}.tmp" "$BE_CONTEXT_FILE"
  fi

  # Deploy only BackendOverlayStack here. BackendAgentRoleStack depends on the
  # platform space ARN in SSM (written by sync-outputs.sh in step 6) and is
  # deployed later in step 7.
  npx cdk deploy BackendOverlayStack --require-approval never --profile "$BE_PROFILE" \
    --app "npx ts-node ${PROJECT_ROOT}/workload/backend/overlay/bin/app.ts" \
    --output "${PROJECT_ROOT}/workload/backend/overlay/cdk.out"
  check_exit 2 $?
fi

# ─── Step 3: Frontend workload (FE) ─────────────────────────────────────────
if [[ "$START_FROM" -le 3 ]]; then
  step 3 "Frontend workload (FE)"

  # The FE stack resolves the BE PrivateLink endpoint service name from FE
  # SSM (valueFromLookup) to create its interface endpoint, so the service
  # name written by the BE overlay (step 2) must be synced FIRST.
  echo ">>> Syncing PrivateLink service name (BE → FE) before FE deploy..."
  "${SCRIPT_DIR}/sync-outputs.sh" --section privatelink
  check_exit 3 $?

  # The FE stack resolves the service name with valueFromLookup, which CDK
  # caches in cdk.context.json. After a teardown/redeploy the BE overlay
  # creates a NEW endpoint service, so a stale cached value would wire the
  # interface endpoint to a service that no longer exists. Reset the cached
  # SSM lookup so CDK re-resolves it fresh on every deploy.
  FE_CONTEXT_FILE="${PROJECT_ROOT}/workload/frontend/cdk.context.json"
  if [[ -f "$FE_CONTEXT_FILE" ]]; then
    echo ">>> Resetting cached PrivateLink SSM context lookup (avoid stale service name)..."
    jq 'with_entries(select(.key | contains("petsite-privatelink-service-name") | not))' \
      "$FE_CONTEXT_FILE" > "${FE_CONTEXT_FILE}.tmp" && mv "${FE_CONTEXT_FILE}.tmp" "$FE_CONTEXT_FILE"
  fi

  echo ""
  npx cdk deploy FrontendStack --require-approval never --profile "$FE_PROFILE" \
    --app "npx ts-node ${PROJECT_ROOT}/workload/frontend/bin/app.ts" \
    --output "${PROJECT_ROOT}/workload/frontend/cdk.out"
  check_exit 3 $?
fi

# ─── Step 4: Agents/infra (OPS) ─────────────────────────────────────────────
if [[ "$START_FROM" -le 4 ]]; then
  step 4 "Agents/infra (OPS)"
  npx cdk deploy --all --require-approval never --profile "$OPS_PROFILE" \
    --app "npx ts-node ${PROJECT_ROOT}/agents/infra/bin/app.ts" \
    --output "${PROJECT_ROOT}/agents/infra/cdk.out"
  check_exit 4 $?

  # CloudFormation creates the KB + data source but never ingests, so a
  # fresh KB is empty until an ingestion job runs. Sync it now (idempotent).
  echo ""
  echo ">>> Syncing KB corpus (ingestion job)..."
  "${SCRIPT_DIR}/sync-kb.sh"
  check_exit 4 $?
fi

# ─── Step 5: Agent Spaces phase 1 (OPS) — spaces only ───────────────────────
if [[ "$START_FROM" -le 5 ]]; then
  step 5 "Agent Spaces phase 1 (OPS) — spaces only"
  # Associations are off for phase 1 only: they need the FE/BE agent roles,
  # which step 7 creates from the space ARNs this step publishes. The context
  # default in agent-spaces/cdk.json is `true` (the steady state, matching the
  # deployed stack), so phase 1 has to opt out explicitly.
  npx cdk deploy --all --require-approval never --profile "$OPS_PROFILE" \
    -c ENABLE_ASSOCIATIONS=false \
    --app "npx ts-node ${PROJECT_ROOT}/agent-spaces/bin/app.ts" \
    --output "${PROJECT_ROOT}/agent-spaces/cdk.out"
  check_exit 5 $?
fi

# ─── Step 6: Sync outputs ───────────────────────────────────────────────────
if [[ "$START_FROM" -le 6 ]]; then
  step 6 "Sync outputs (cross-account SSM)"
  "${SCRIPT_DIR}/sync-outputs.sh"
  check_exit 6 $?
fi

# ─── Step 7: Agent-role stacks (FE + BE) ────────────────────────────────────
if [[ "$START_FROM" -le 7 ]]; then
  step 7 "Agent-role stacks (FE + BE)"

  echo ">>> Deploying FrontendAgentRoleStack (FE)..."
  npx cdk deploy FrontendAgentRoleStack --require-approval never --profile "$FE_PROFILE" \
    --app "npx ts-node ${PROJECT_ROOT}/workload/frontend/bin/app.ts" \
    --output "${PROJECT_ROOT}/workload/frontend/cdk.out"
  check_exit 7 $?

  echo ""
  echo ">>> Deploying BackendAgentRoleStack (BE)..."
  npx cdk deploy BackendAgentRoleStack --require-approval never --profile "$BE_PROFILE" \
    --app "npx ts-node ${PROJECT_ROOT}/workload/backend/overlay/bin/app.ts" \
    --output "${PROJECT_ROOT}/workload/backend/overlay/cdk.out"
  check_exit 7 $?

  echo ""
  echo ">>> Waiting 60s for IAM propagation before associations..."
  sleep 60
fi

# ─── Step 8: Agent Spaces phase 2 (OPS) — associations ─────────────────────
if [[ "$START_FROM" -le 8 ]]; then
  step 8 "Agent Spaces phase 2 (OPS) — associations"
  npx cdk deploy --all --require-approval never --profile "$OPS_PROFILE" \
    -c ENABLE_ASSOCIATIONS=true \
    --app "npx ts-node ${PROJECT_ROOT}/agent-spaces/bin/app.ts" \
    --output "${PROJECT_ROOT}/agent-spaces/cdk.out"
  check_exit 8 $?

  # Operator Web App federation identifier — MANUAL, one-time per space.
  # Neither the DevOps Agent API nor CloudFormation can set it, so deploys
  # never touch it (an identifier already set in the console is preserved).
  # Tolerant on purpose (Requirement 10.2): the pre-refactor read used
  # `// empty`, so an unset identifier printed the recovery hint below rather
  # than aborting a deployment that is otherwise complete at step 8. The
  # resolver is fatal on a missing required field, so its exit is absorbed here
  # and the empty value falls through to the same hint. preflight.sh (step 0)
  # is what actually fails a deploy for an unset identifier.
  FEDERATION_ID="$(config::get operator.federationIdentifier 2>/dev/null || true)"
  echo ""
  echo ">>> MANUAL STEP (one-time): set the Operator Web App federation identifier"
  echo "    for BOTH agent spaces in the console: DevOps Agent → space →"
  echo "    Operator Access tab → federation identifier: ${FEDERATION_ID:-<set operator.federationIdentifier in config/accounts.json>}"
  echo "    (Not settable via API/CFN; already-set values are never overwritten.)"
fi

# ─── Step 9: Skills packaging (upload + providers printed) ──────────────────
if [[ "$START_FROM" -le 9 ]]; then
  step 9 "Skills packaging (upload + capability providers printed)"
  "${SCRIPT_DIR}/package-skills.sh"
  check_exit 9 $?

  # Printed rather than run, deliberately, and for the same reason as the
  # registrations below: everything in this step that MUTATES the DevOps Agent
  # control plane is left to the Replicator. Two specific reasons for the skills
  # upload — (1) UpdateAsset bumps an asset version on every call, so a
  # `--start-from 9` re-run would silently climb version numbers on a deploy
  # that is meant to be idempotent; (2) the Active/Inactive toggle is the whole
  # skills-before/after axis and is console-only, so a Replicator running the
  # skills-OFF baseline must not have a redeploy re-upload the catalog under them.
  echo ""
  echo ">>> Skills packaged into dist/skills/<space>/. Upload them (per-space catalogs):"
  echo "    scripts/upload-skills.sh                 # create-asset/update-asset, verified with list-assets"
  echo "    (--dry-run makes no AWS calls. Needs an AWS CLI whose devops-agent"
  echo "     model carries the asset operations — preflight.sh check P6. Manual"
  echo "     Operator Web App upload remains the documented fallback.)"
  echo ""
  echo ">>> Register the two webhooks (eventChannel → per-space secret):"
  echo "    scripts/register-webhook.sh --space app-team    # aiops-poc/webhook-credentials"
  echo "    scripts/register-webhook.sh --space platform     # aiops-poc/platform-webhook-credentials"
  echo "    (The bridge routes aiops-poc-be-infra-* alarms to the platform"
  echo "     secret, everything else to app-team — the dual-path incident routing.)"
  echo ""
  echo ">>> Register capability providers (PRIMARY = MCP; A2A variants are alternates):"
  echo "    - platform space → app-team (space-to-space, live investigator):"
  echo "      scripts/register-platform-space-mcp.sh"
  echo "    - fallback agents → app-team (knowledge-only investigate tool):"
  echo "      scripts/register-fallback-agents-mcp.sh --peer both"
  echo "    Both print pre-filled manual console steps if the account MCP gate fires."
  echo "    See agent-spaces/README.md for detailed steps."
fi

# ─── Step 10: Restart petsite so tasks pick up final SSM parameters ─────────
# petsite reads /petstore/* SSM parameters at startup. The final values
# (PrivateLink endpoint URLs from the FE stack + API Gateway URLs from
# sync-outputs) may have changed after the currently running tasks started,
# so force a new deployment. Idempotent and safe to re-run.
if [[ "$START_FROM" -le 10 ]]; then
  step 10 "Restart petsite ECS service (pick up final /petstore params)"
  aws ecs update-service \
    --cluster aiops-poc-petsite \
    --service petsite \
    --force-new-deployment \
    --profile "$FE_PROFILE" \
    --region "$FE_REGION" > /dev/null
  check_exit 10 $?
  echo ">>> petsite force-new-deployment triggered."
fi

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Full deployment complete. Steps executed: ${STEP_COUNT}"
echo ""
echo "  Next steps:"
echo "    1. Register both webhooks (if not already):"
echo "         scripts/register-webhook.sh --space app-team"
echo "         scripts/register-webhook.sh --space platform"
echo "    2. Register capability providers:"
echo "         scripts/register-platform-space-mcp.sh"
echo "         scripts/register-fallback-agents-mcp.sh --peer both"
echo "       Complete any manual console steps they print (see agent-spaces/README.md)"
echo "    3. Upload the skills packaged in step 9 (per-space catalogs):"
echo "         scripts/upload-skills.sh"
echo "       The Inactive/Active toggle per space stays a console step."
echo "    4. Run smoke test: scripts/smoke-test.sh"
echo "═══════════════════════════════════════════════════════════════════"
