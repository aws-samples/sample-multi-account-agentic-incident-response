#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-upstream.sh — Deploy the upstream PetAdoptions backend via its
# CodeBuild CDK deployment mechanism, without forking application source code.
#
# This script wraps the upstream aws-samples/one-observability-demo deployment
# by launching a CloudFormation stack that provisions a CodeBuild project.
# CodeBuild fetches the pinned upstream ref (upstream.ref in
# config/accounts.json — a branch, a tag, or a full commit SHA) and executes the
# CDK deploy within the target account.
#
# Usage:
#   ./deploy-upstream.sh [--profile <aws-profile>] [--region <region>]
#                        [--stack-name <name>] [--timeout-minutes <n>]
#                        [--wait] [--destroy] [--seed-only]
#
# Parameters are read from ../../config/accounts.json by default. CLI flags
# override config values.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
CFN_TEMPLATE="${SCRIPT_DIR}/cfn-codebuild-stack.yaml"

# The backend account and the upstream coordinates come from the
# Config_Resolver — the one shared location that reads config/accounts.json
# (Requirement 2.6).
source "${PROJECT_ROOT}/scripts/lib/config.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────
STACK_NAME="aiops-poc-upstream-backend"
WAIT=false
DESTROY=false
SEED_ONLY=false
PROFILE_FLAG=""
REGION_FLAG=""

# The CodeBuild build cap, in minutes, passed to CloudFormation on EVERY run
# (see the --parameter-overrides call). It lives here beside --stack-name rather
# than in config/accounts.json on purpose: a build timeout is not a value that
# differs between replicators — it is an operational knob with a sane default —
# and config/accounts.json is the gated Replicator_Input surface, which is not
# widened for values that are the same for everyone. There is deliberately no
# environment variable either; one flag with one default is the whole knob.
BUILD_TIMEOUT_MINUTES=120

# The template's own bounds for BuildTimeoutMinutes (MinValue/MaxValue in
# cfn-codebuild-stack.yaml, which are CodeBuild's own limits). Checked locally so
# a bad value fails in a millisecond with a message naming the range, instead of
# CloudFormation rejecting the whole deploy half a minute in.
BUILD_TIMEOUT_MIN=10
BUILD_TIMEOUT_MAX=2160

# ─── Parse CLI args ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)  PROFILE_FLAG="$2"; shift 2 ;;
    --region)   REGION_FLAG="$2"; shift 2 ;;
    --stack-name) STACK_NAME="$2"; shift 2 ;;
    --timeout-minutes) BUILD_TIMEOUT_MINUTES="$2"; shift 2 ;;
    --wait)     WAIT=true; shift ;;
    --destroy)  DESTROY=true; shift ;;
    --seed-only) SEED_ONLY=true; shift ;;
    -h|--help)
      echo "Usage:"
      echo "  ./deploy-upstream.sh [--profile <aws-profile>] [--region <region>]"
      echo "                       [--stack-name <name>] [--timeout-minutes <n>]"
      echo "                       [--wait] [--destroy] [--seed-only]"
      echo ""
      echo "Options:"
      echo "  --profile    AWS CLI profile (default: from config/accounts.json)"
      echo "  --region     AWS region (default: from config/accounts.json)"
      echo "  --stack-name CloudFormation stack name (default: aiops-poc-upstream-backend)"
      echo "  --timeout-minutes  CodeBuild build cap in minutes (default: ${BUILD_TIMEOUT_MINUTES},"
      echo "               allowed ${BUILD_TIMEOUT_MIN}-${BUILD_TIMEOUT_MAX}). Passed on every run, so it is"
      echo "               authoritative rather than inherited from the existing stack"
      echo "  --wait       Block until CodeBuild deployment completes"
      echo "  --destroy    Delete the CodeBuild stack (not the upstream resources)"
      echo "  --seed-only  Skip deploy; run RDS + DynamoDB seeding against an"
      echo "               already-deployed upstream"
      echo "  -h, --help   Show this help"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Validate the build cap locally ──────────────────────────────────────────
# Against the template's own MinValue/MaxValue, before anything is deployed.
case "$BUILD_TIMEOUT_MINUTES" in
  ''|*[!0-9]*)
    echo "ERROR: --timeout-minutes must be a whole number of minutes, got '${BUILD_TIMEOUT_MINUTES}'." >&2
    echo "       Allowed range: ${BUILD_TIMEOUT_MIN}-${BUILD_TIMEOUT_MAX} (cfn-codebuild-stack.yaml's own bounds)." >&2
    exit 1 ;;
esac
if [[ "$BUILD_TIMEOUT_MINUTES" -lt "$BUILD_TIMEOUT_MIN" || "$BUILD_TIMEOUT_MINUTES" -gt "$BUILD_TIMEOUT_MAX" ]]; then
  echo "ERROR: --timeout-minutes ${BUILD_TIMEOUT_MINUTES} is outside the allowed range ${BUILD_TIMEOUT_MIN}-${BUILD_TIMEOUT_MAX}." >&2
  echo "       Those are BuildTimeoutMinutes' MinValue/MaxValue in cfn-codebuild-stack.yaml," >&2
  echo "       which are CodeBuild's own limits. Nothing was deployed." >&2
  exit 1
fi

# ─── Read config ─────────────────────────────────────────────────────────────
# config::init checks jq and the config file itself, naming the missing
# prerequisite or the file to create (Requirements 3.1, 3.4).
config::init

# Backend account, with the CLI flags at the top of the precedence chain
# (flag > env > config file > template default).
config::account be --profile-flag "$PROFILE_FLAG" --region-flag "$REGION_FLAG"
BE_ACCOUNT_ID="$CONFIG_BE_ACCOUNT"
BE_REGION="$CONFIG_BE_REGION"
BE_PROFILE="$CONFIG_BE_PROFILE"

# Upstream coordinates
UPSTREAM_ORG="$(config::get upstream.org)"
UPSTREAM_REPO="$(config::get upstream.repo)"
UPSTREAM_REF="$(config::get upstream.ref)"

PROFILE="$BE_PROFILE"
REGION="$BE_REGION"

UPSTREAM_REPO_URL="https://github.com/${UPSTREAM_ORG}/${UPSTREAM_REPO}.git"

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  AI-Ops PoC — Upstream Backend Deployment                        ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Account:    ${BE_ACCOUNT_ID}"
echo "  Region:     ${REGION}"
echo "  Profile:    ${PROFILE}"
echo "  Stack:      ${STACK_NAME}"
echo "  Upstream:   ${UPSTREAM_REPO_URL}@${UPSTREAM_REF}"
echo "  Build cap:  ${BUILD_TIMEOUT_MINUTES} minutes (--timeout-minutes to change)"
echo ""

# ─── AWS CLI profile arg ─────────────────────────────────────────────────────
AWS_ARGS=()
if [[ -n "$PROFILE" ]]; then
  AWS_ARGS+=(--profile "$PROFILE")
fi
AWS_ARGS+=(--region "$REGION")

# ─── Seeding functions (post-deploy data initialization) ────────────────────
# The upstream one-observability-demo treats BOTH database seedings as
# post-deploy steps (its pipeline runs them as separate CodeBuild steps; see
# upstream docs "operations/seeding" and lib/stages/storage.ts):
#   - RDS:      invoke the upstream-deployed `rds-seeder` Lambda
#               (creates the transactions/users tables in Aurora)
#   - DynamoDB: run the upstream `src/cdk/scripts/seed-dynamodb.sh` script
#               against the pets + petfoods tables (table names from the
#               upstream SSM contract: /petstore/dynamodbtablename and
#               /petstore/foods_table_name)
# Our CodeBuild wrapper runs `cdk deploy --all` only, so without these steps
# the Aurora tables never exist (petsite /PetListAdoptions errors) and the
# DynamoDB tables stay empty (petsite homepage shows "No Pets found").

# Seed Aurora via the upstream rds-seeder Lambda. Idempotent: the seeder
# DROPs IF EXISTS before CREATE, so re-running is safe.
seed_rds() {
  local rds_seeder_function="${RDS_SEEDER_FUNCTION:-rds-seeder}"
  echo ""
  echo ">>> Seeding Aurora database via ${rds_seeder_function} Lambda (creates transactions/users tables)..."

  local seed_ok=false
  local attempt
  for attempt in 1 2 3 4 5; do
    local seed_out_file
    seed_out_file="$(mktemp)"
    local seed_status
    seed_status=$(aws lambda invoke \
      --function-name "$rds_seeder_function" \
      --payload '{}' \
      --cli-binary-format raw-in-base64-out \
      "$seed_out_file" \
      --query "StatusCode" --output text \
      "${AWS_ARGS[@]}" 2>/dev/null || echo "0")

    local seed_body
    seed_body="$(cat "$seed_out_file" 2>/dev/null || echo '')"
    rm -f "$seed_out_file"

    # The seeder returns {"statusCode": 200, ...} on success; a 500 body
    # (e.g. DB not reachable yet) or an invoke failure warrants a retry.
    if [[ "$seed_status" == "200" && "$seed_body" == *'"statusCode": 200'* ]]; then
      echo "    ✓ RDS seeding succeeded (transactions/users tables created)."
      seed_ok=true
      break
    fi

    echo "    Attempt ${attempt}/5: seeding not confirmed (invoke status ${seed_status}); retrying in 20s..."
    echo "      response: ${seed_body}"
    sleep 20
  done

  if [[ "$seed_ok" != "true" ]]; then
    echo "ERROR: RDS seeding did not succeed after 5 attempts." >&2
    echo "       The transactions/users tables may be missing; petlistadoption" >&2
    echo "       and payforadoption will error until seeded." >&2
    echo "       Inspect logs: /aws/lambda/${rds_seeder_function}" >&2
    return 1
  fi
}

# Return the item count of a DynamoDB table (scan COUNT).
ddb_count() {
  aws dynamodb scan \
    --table-name "$1" \
    --select COUNT \
    --query "Count" --output text \
    "${AWS_ARGS[@]}" 2>/dev/null || echo "-1"
}

# Seed the DynamoDB pets + petfoods tables using the UPSTREAM seeder script
# and seed data (src/cdk/scripts/seed-dynamodb.sh + seed.json +
# petfood-seed.json at the pinned ref) — the item schema is derived from
# upstream source, not reinvented, so petsearch-java's queries and the S3
# image-key layout (puppies/kittens/bunnies + petfood/) match exactly.
# Idempotent: put-item upserts by key, so re-running is safe.
seed_dynamodb() {
  echo ""
  echo ">>> Seeding DynamoDB pets + petfoods tables (upstream seed-dynamodb.sh)..."

  # Table names from the upstream SSM contract
  local pets_table foods_table
  pets_table=$(aws ssm get-parameter --name /petstore/dynamodbtablename \
    --query "Parameter.Value" --output text "${AWS_ARGS[@]}" 2>/dev/null || echo "")
  foods_table=$(aws ssm get-parameter --name /petstore/foods_table_name \
    --query "Parameter.Value" --output text "${AWS_ARGS[@]}" 2>/dev/null || echo "")

  if [[ -z "$pets_table" || -z "$foods_table" ]]; then
    echo "ERROR: Could not resolve DynamoDB table names from SSM" >&2
    echo "       (/petstore/dynamodbtablename, /petstore/foods_table_name)." >&2
    echo "       Is the upstream deployed?" >&2
    return 1
  fi

  echo "    Pets table:    ${pets_table}"
  echo "    Petfood table: ${foods_table}"

  # Fetch the upstream seeder + seed data at the pinned ref (single source
  # of truth for the item schema).
  local seed_src_dir
  seed_src_dir="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: cleanup path is fixed at creation
  trap "rm -rf '${seed_src_dir}'" RETURN
  echo "    Fetching upstream ${UPSTREAM_REPO_URL}@${UPSTREAM_REF} (seed data)..."
  # Fetch by ref rather than `git clone --branch`: --branch only accepts a branch
  # or tag name, so a commit SHA — the only value that actually pins anything —
  # fails with "Remote branch <sha> not found in upstream origin". `git fetch
  # <ref>` accepts a branch, a tag, or a FULL 40-character SHA. `git -C` keeps
  # the caller's working directory untouched; the RETURN trap above still owns
  # the cleanup of ${seed_src_dir}, which mktemp -d already created.
  if ! { git init --quiet "$seed_src_dir" \
      && git -C "$seed_src_dir" remote add origin "$UPSTREAM_REPO_URL" \
      && git -C "$seed_src_dir" fetch --quiet --depth 1 origin "$UPSTREAM_REF" \
      && git -C "$seed_src_dir" checkout --quiet FETCH_HEAD; }; then
    echo "ERROR: Could not fetch upstream repo for seed data." >&2
    echo "       upstream.ref (${UPSTREAM_REF}) must be a branch, a tag, or a" >&2
    echo "       FULL 40-character commit SHA — an abbreviated SHA is not" >&2
    echo "       fetchable and fails here." >&2
    return 1
  fi

  local seeder="${seed_src_dir}/src/cdk/scripts/seed-dynamodb.sh"
  if [[ ! -x "$seeder" ]]; then
    chmod +x "$seeder" 2>/dev/null || true
  fi
  if [[ ! -f "$seeder" ]]; then
    echo "ERROR: Upstream seeder not found at src/cdk/scripts/seed-dynamodb.sh" >&2
    echo "       (upstream ref ${UPSTREAM_REF} may have moved it)." >&2
    return 1
  fi

  # The upstream seeder uses the ambient AWS CLI configuration (no
  # --profile/--region args), so export ours for its subshell.
  local seed_env=(AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION")
  if [[ -n "$PROFILE" ]]; then
    seed_env+=(AWS_PROFILE="$PROFILE")
  fi

  local target attempt seeded
  for target in "pets:${pets_table}" "petfood:${foods_table}"; do
    local kind="${target%%:*}"
    local table="${target#*:}"
    seeded=false
    for attempt in 1 2 3; do
      if env "${seed_env[@]}" "$seeder" "$kind" "$table" > /dev/null; then
        seeded=true
        break
      fi
      echo "    Attempt ${attempt}/3: ${kind} seeding failed; retrying in 15s..."
      sleep 15
    done
    if [[ "$seeded" != "true" ]]; then
      echo "ERROR: DynamoDB ${kind} seeding failed after 3 attempts (table ${table})." >&2
      return 1
    fi
  done

  # Verify: both tables must contain items
  local pets_count foods_count
  pets_count=$(ddb_count "$pets_table")
  foods_count=$(ddb_count "$foods_table")
  if [[ "$pets_count" -gt 0 && "$foods_count" -gt 0 ]]; then
    echo "    ✓ DynamoDB seeding succeeded (pets: ${pets_count} items, petfood: ${foods_count} items)."
  else
    echo "ERROR: DynamoDB seeding verification failed" >&2
    echo "       (pets count: ${pets_count}, petfood count: ${foods_count})." >&2
    return 1
  fi
}

# ─── Post-build image assertion (read-only) ─────────────────────────────────
# The upstream ECS services pull their image by ECR URI with no tag — i.e.
# `:latest` — and the only thing that publishes that tag is the container pipeline
# the upstream CDK creates in this account. Without this check nothing says a
# build failed: DevMicroservicesStack sits in CREATE_IN_PROGRESS for
# ~45 minutes while its ECS service fails placement with
# `CannotPullContainerError: ... not found`, three layers away from the failed
# `Build-<service>` action that actually caused it. This check names the empty
# repository, the failed pipeline action, and the retry command instead.
#
# It WARNS and never changes this script's exit status. That is deliberate:
#   - the failure belongs to upstream's pipeline, not to anything this script
#     deploys, and the remedy (retry-stage-execution) is the operator's call;
#   - the check depends on read permissions (codepipeline:GetPipeline*,
#     ecr:ListImages) and on upstream keeping its pipeline name and shape. Any of
#     those changing would otherwise turn a successful deploy into a failed one —
#     failing the deploy for a reason unrelated to the images is exactly what must
#     not happen;
#   - on the failing-build path the script already exits non-zero, so the check
#     adds a named cause to an existing failure rather than inventing one.
# Every call it makes is read-only.
UPSTREAM_PIPELINE_NAME="DevApplicationsStack-pipeline"

# The repositories to assert, DERIVED from upstream's own pipeline definition
# rather than hardcoded: each Build-stage action that publishes an image carries
# both the repository name and the tag it pushes in its own configuration, so the
# expected set follows whatever upstream's application list is at the pinned ref.
# Prints one "<repo>\t<tags>" row per publishing action. Actions with no
# ECRRepositoryName (upstream builds the PetFood agent through a plain CodeBuild
# action) cannot be asserted this way and are left out rather than guessed at.
upstream_image_targets() {
  aws codepipeline get-pipeline \
    --name "$UPSTREAM_PIPELINE_NAME" \
    --query "pipeline.stages[?name=='Build'].actions[] | [?configuration.ECRRepositoryName].configuration.[ECRRepositoryName,ImageTags]" \
    --output text \
    "${AWS_ARGS[@]}" 2>/dev/null || true
}

# Print the Build stage's failed actions, with upstream's own error text, and echo
# the pipeline execution id the retry command needs.
report_failed_build_actions() {
  local state failed
  state="$(aws codepipeline get-pipeline-state \
    --name "$UPSTREAM_PIPELINE_NAME" \
    --output json \
    "${AWS_ARGS[@]}" 2>/dev/null || true)"

  if [[ -z "${state//[[:space:]]/}" ]]; then
    echo "      (could not read ${UPSTREAM_PIPELINE_NAME}'s state to name the failed action)" >&2
    return 0
  fi

  failed="$(printf '%s' "$state" | jq -r '
    .stageStates[]? | select(.stageName == "Build") | .actionStates[]?
    | select((.latestExecution.status // "") | test("Failed|Abandoned"))
    | "        \(.actionName): \(.latestExecution.status) — \(.latestExecution.errorDetails.message // "no error detail recorded")"
  ' 2>/dev/null || true)"

  if [[ -n "${failed//[[:space:]]/}" ]]; then
    echo "" >&2
    echo "      Failed build action(s) in ${UPSTREAM_PIPELINE_NAME}:" >&2
    printf '%s\n' "$failed" >&2
  else
    echo "" >&2
    echo "      ${UPSTREAM_PIPELINE_NAME} reports no currently-failed Build action —" >&2
    echo "      the build may still be running, or a retry may have superseded the" >&2
    echo "      failure. Read the stage state yourself before retrying." >&2
  fi

  printf '%s' "$state" | jq -r '
    .stageStates[]? | select(.stageName == "Build")
    | .latestExecution.pipelineExecutionId // empty
  ' 2>/dev/null || true
}

assert_upstream_images() {
  echo ""
  echo ">>> Checking that every upstream application image reached ECR (read-only)..."

  local targets
  targets="$(upstream_image_targets)"
  if [[ -z "${targets//[[:space:]]/}" ]]; then
    echo "    WARN: could not read the Build stage of ${UPSTREAM_PIPELINE_NAME}, so the"
    echo "          expected repository set is unknown — skipping the image check"
    echo "          rather than asserting a guessed list. Inspect it with:"
    echo "            aws codepipeline get-pipeline-state --name ${UPSTREAM_PIPELINE_NAME} ${AWS_ARGS[*]}"
    return 0
  fi

  local repo tags tag found checked=0 missing="" unreadable=""
  while IFS=$'\t' read -r repo tags; do
    [[ -n "$repo" ]] || continue
    # ImageTags may list several tags; the first is the one the ECS services pull.
    tag="${tags%%,*}"
    if [[ -z "$tag" || "$tag" == "None" ]]; then
      tag="latest"
    fi
    checked=$((checked + 1))

    if ! found="$(aws ecr list-images \
      --repository-name "$repo" \
      --filter tagStatus=TAGGED \
      --query "imageIds[?imageTag=='${tag}'].imageTag | [0]" \
      --output text \
      "${AWS_ARGS[@]}" 2>/dev/null)"; then
      unreadable="${unreadable} ${repo}"
      continue
    fi

    if [[ "$found" == "$tag" ]]; then
      echo "    ✓ ${repo}:${tag}"
    else
      missing="${missing} ${repo}:${tag}"
    fi
  done <<< "$targets"

  if [[ -n "${unreadable//[[:space:]]/}" ]]; then
    echo "    WARN: could not read tags for:${unreadable}"
    echo "          (an ecr:ListImages denial, or a repository upstream has not created yet)"
  fi

  if [[ -z "${missing//[[:space:]]/}" ]]; then
    echo "    ✓ all ${checked} upstream application image(s) present."
    return 0
  fi

  # Loud, but not fatal — the rationale is at the top of this section.
  local entry exec_id
  echo "" >&2
  echo "WARN: the upstream workload is INCOMPLETE — these images never reached ECR:" >&2
  for entry in $missing; do
    echo "        ${entry}" >&2
  done
  echo "" >&2
  echo "      Every ECS service that pulls one of them fails placement with" >&2
  echo "      'CannotPullContainerError: ... not found', and the upstream stack that" >&2
  echo "      waits on that service (DevMicroservicesStack) sits in" >&2
  echo "      CREATE_IN_PROGRESS for ~45 minutes before it gives up. The image build" >&2
  echo "      is the cause; ECS is only where it shows up." >&2

  exec_id="$(report_failed_build_actions | tail -n 1)"

  echo "" >&2
  echo "      Retry the failed action. Upstream's Build stage retries FAILED_ACTIONS" >&2
  echo "      once by itself, so a second failure needs this:" >&2
  echo "" >&2
  echo "        aws codepipeline retry-stage-execution \\" >&2
  echo "          --pipeline-name ${UPSTREAM_PIPELINE_NAME} \\" >&2
  echo "          --stage-name Build \\" >&2
  echo "          --pipeline-execution-id ${exec_id:-<pipeline-execution-id>} \\" >&2
  echo "          --retry-mode FAILED_ACTIONS ${AWS_ARGS[*]}" >&2
  echo "" >&2
  echo "      Once the image lands, the waiting stack settles on its own. Full" >&2
  echo "      explanation, including the local docker buildx escape hatch:" >&2
  echo "      docs/deployment.md#troubleshooting-devmicroservicesstack-sits-waiting-then-fails" >&2
}

# ─── Seed-only path ──────────────────────────────────────────────────────────
if [[ "$SEED_ONLY" == "true" ]]; then
  echo ">>> --seed-only: seeding databases of the already-deployed upstream."
  seed_rds
  seed_dynamodb
  echo ""
  echo ">>> Seeding complete."
  exit 0
fi

# ─── Destroy path ────────────────────────────────────────────────────────────
if [[ "$DESTROY" == "true" ]]; then
  echo ">>> Destroying stack: ${STACK_NAME}"
  echo ""
  echo "NOTE: This removes the CodeBuild project and its deployment role."
  echo "To fully clean up the upstream PetAdoptions resources, also run the"
  echo "upstream cleanup procedure:"
  echo "  https://aws-samples.github.io/one-observability-demo/operations/cleanup/"
  echo ""

  aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" \
    "${AWS_ARGS[@]}"

  if [[ "$WAIT" == "true" ]]; then
    echo ">>> Waiting for stack deletion..."
    aws cloudformation wait stack-delete-complete \
      --stack-name "$STACK_NAME" \
      "${AWS_ARGS[@]}"
    echo ">>> Stack deleted."
  else
    echo ">>> Delete initiated. Use --wait to block until complete."
  fi
  exit 0
fi

# ─── Deploy path ─────────────────────────────────────────────────────────────
echo ">>> Deploying CloudFormation stack: ${STACK_NAME}"
echo "    Template: ${CFN_TEMPLATE}"
echo ""

# BuildTimeoutMinutes is passed on EVERY run, and that is the whole point of it
# being here. `aws cloudformation deploy` sends UsePreviousValue for any parameter
# absent from --parameter-overrides, so a stack first created with a 60-minute cap
# keeps 60 forever and raising the template's default is a silent no-op on the
# re-run — which is precisely the run that needs it, having just been timed out.
# Passing it makes the value authoritative rather than inherited.
aws cloudformation deploy \
  --template-file "$CFN_TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    UpstreamRepoUrl="$UPSTREAM_REPO_URL" \
    UpstreamRef="$UPSTREAM_REF" \
    UpstreamOrg="$UPSTREAM_ORG" \
    UpstreamRepo="$UPSTREAM_REPO" \
    BuildTimeoutMinutes="$BUILD_TIMEOUT_MINUTES" \
  --tags \
    Project=aiops-poc \
    Component=upstream-backend \
    ManagedBy=aiops-poc-deploy \
  "${AWS_ARGS[@]}"

echo ""
echo ">>> CloudFormation stack deployed. CodeBuild project created."
echo ""
echo ">>> Starting CodeBuild deployment build..."

# Get the CodeBuild project name from stack outputs
CB_PROJECT=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='CodeBuildProjectName'].OutputValue" \
  --output text \
  "${AWS_ARGS[@]}")

if [[ -z "$CB_PROJECT" || "$CB_PROJECT" == "None" ]]; then
  echo "ERROR: Could not retrieve CodeBuild project name from stack outputs." >&2
  exit 1
fi

echo "    CodeBuild project: ${CB_PROJECT}"

# Start the build
BUILD_ID=$(aws codebuild start-build \
  --project-name "$CB_PROJECT" \
  --query "build.id" \
  --output text \
  "${AWS_ARGS[@]}")

echo "    Build ID: ${BUILD_ID}"
echo ""

if [[ "$WAIT" == "true" ]]; then
  echo ">>> Waiting for CodeBuild deployment to complete..."
  echo "    (A full PetAdoptions deploy takes over an hour: 45-90 minutes.)"
  echo "    (This build's own cap is ${BUILD_TIMEOUT_MINUTES} minutes, just set on the project.)"
  echo ""

  while true; do
    BUILD_STATUS=$(aws codebuild batch-get-builds \
      --ids "$BUILD_ID" \
      --query "builds[0].buildStatus" \
      --output text \
      "${AWS_ARGS[@]}")

    case "$BUILD_STATUS" in
      SUCCEEDED)
        echo ">>> CodeBuild deployment SUCCEEDED."
        UPSTREAM_BUILD_SUCCEEDED=true
        break
        ;;
      FAILED|FAULT|TIMED_OUT|STOPPED)
        echo "ERROR: CodeBuild deployment ended with status: ${BUILD_STATUS}" >&2
        echo "       Check the CodeBuild logs in the AWS Console for details." >&2
        # A build killed while an upstream stack waits on an image that never got
        # built reads as a CDK failure and is not one, so name the images before
        # exiting. Read-only, and it cannot change this exit status.
        assert_upstream_images
        exit 1
        ;;
      IN_PROGRESS)
        echo "    ...still building (status: IN_PROGRESS)"
        sleep 30
        ;;
      *)
        echo "    ...status: ${BUILD_STATUS}"
        sleep 30
        ;;
    esac
  done
else
  echo ">>> Build started. Monitor progress in the AWS Console or run:"
  echo "    aws codebuild batch-get-builds --ids ${BUILD_ID} ${AWS_ARGS[*]}"
  echo ""
  echo "    Use --wait to block until the build completes."
fi

# ─── Post-deploy seeding (Aurora + DynamoDB) ─────────────────────────────────
# Upstream treats both as separate post-deploy steps (see seeding functions
# above). Run them here, after the upstream deploy has completed, so the
# rds-seeder Lambda, Aurora, and the DynamoDB tables all exist. Only runs in
# --wait mode (without --wait the upstream resources are not guaranteed to
# exist yet).
if [[ "${WAIT}" == "true" && "${UPSTREAM_BUILD_SUCCEEDED:-false}" == "true" ]]; then
  # Assert the images before seeding, so the run says plainly whether the
  # workload is complete. Seeding touches Aurora and DynamoDB, not the container
  # images, so a missing image is invisible from its result either way.
  assert_upstream_images
  seed_rds
  seed_dynamodb
fi

echo ""
echo ">>> Done. Upstream PetAdoptions backend deployed to account ${BE_ACCOUNT_ID}."
