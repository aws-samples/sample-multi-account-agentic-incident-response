#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bootstrap.sh — CDK bootstrap all three accounts for the AI-Ops PoC
#
# Runs `cdk bootstrap` against each account/region/profile defined in
# config/accounts.json so that CDK stacks can be deployed.
#
# Before touching an account it reads any existing CDKToolkit stack's Qualifier
# parameter and refuses (exit 99) when that stack belongs to a different
# qualifier — updating it in place would delete the staging roles that
# qualifier's deployments depend on. The bootstrap it does run always passes
# --qualifier explicitly, so it can never inherit a flipped stack's qualifier and
# report success while fixing nothing. See docs/deployment.md,
# "Troubleshooting: two CDK toolkit stacks in one account".
#
# Usage:
#   scripts/bootstrap.sh [--account <be|fe|ops>] [--skip-preflight] [--help]
#
# Flags:
#   --account          Bootstrap only a single account (be, fe, or ops)
#   --skip-preflight   Do not run scripts/preflight.sh first (see below)
#   -h, --help         Show this help
#
# Requirements: 15.1, 9.3
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Every account, region and profile below comes from the Config_Resolver — the
# one shared location that reads config/accounts.json (Requirement 2.6).
source "${PROJECT_ROOT}/scripts/lib/config.sh"

# ─── Parse flags ─────────────────────────────────────────────────────────────
ONLY_ACCOUNT=""
SKIP_PREFLIGHT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account) ONLY_ACCOUNT="$2"; shift 2 ;;
    --skip-preflight) SKIP_PREFLIGHT=true; shift ;;
    -h|--help)
      echo "Usage: scripts/bootstrap.sh [--account <be|fe|ops>] [--skip-preflight]"
      echo ""
      echo "CDK bootstrap all three PoC accounts (or a single one)."
      echo ""
      echo "Flags:"
      echo "  --account          Bootstrap only one account: be, fe, or ops"
      echo "  --skip-preflight   Skip scripts/preflight.sh (parameter/config gate)"
      echo "  -h, --help         Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Validate config ────────────────────────────────────────────────────────
# config::init checks jq and the config file itself, naming the missing
# prerequisite or the file to create (Requirements 3.1, 3.4).
config::init

if ! command -v cdk &>/dev/null; then
  echo "ERROR: AWS CDK CLI (cdk) is required but not installed." >&2
  exit 1
fi

# The toolkit-stack guard below reads CloudFormation through the AWS CLI.
if ! command -v aws &>/dev/null; then
  echo "ERROR: AWS CLI (aws) is required but not installed." >&2
  exit 1
fi

# ─── Preflight (Requirement 9.3) ─────────────────────────────────────────────
# Runs before the first AWS call — the first one is the CDKToolkit describe-stacks
# in assert_toolkit_not_foreign below — so
# an unset account ID, a value still holding a placeholder, a region split
# across the three accounts, or a stale cdk.context.json cache fails here in a
# second instead of half-way through bootstrapping. preflight.sh makes no AWS
# calls of its own, so this costs nothing and needs no credentials.
#
# --skip-preflight is a deliberate escape hatch. The gate is static tooling in
# front of an operator's own accounts, and a Replicator who knows more than a
# static check — a deliberate experiment, or a check that is itself broken
# mid-refactor — must never be locked out of deploying. It is opt-in and
# announces itself rather than being the default.
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

BE_ACCOUNT="$CONFIG_BE_ACCOUNT"
BE_REGION="$CONFIG_BE_REGION"
BE_PROFILE="$CONFIG_BE_PROFILE"

FE_ACCOUNT="$CONFIG_FE_ACCOUNT"
FE_REGION="$CONFIG_FE_REGION"
FE_PROFILE="$CONFIG_FE_PROFILE"

OPS_ACCOUNT="$CONFIG_OPS_ACCOUNT"
OPS_REGION="$CONFIG_OPS_REGION"
OPS_PROFILE="$CONFIG_OPS_PROFILE"

# ─── Helpers ─────────────────────────────────────────────────────────────────
# The qualifier this repo's four CDK apps are pinned to. It is CDK's own default
# and the apps set it explicitly (DefaultStackSynthesizer), so no ambient
# cdk.json context can move them off it.
DEFAULT_QUALIFIER="hnb659fds"

# The stack name `cdk bootstrap` writes to when --toolkit-stack-name is omitted.
DEFAULT_TOOLKIT_STACK="CDKToolkit"

# Read the Qualifier parameter off an existing CDKToolkit stack.
#
# Prints the qualifier when the stack exists and carries one, and nothing at all
# when the stack does not exist. Every failure mode collapses to "nothing" on
# purpose: the caller treats an unreadable answer as "no stack", which leads to
# the ordinary `cdk bootstrap` path — the same thing this script did before the
# check existed. A missing describe-stacks permission therefore cannot turn into
# a refusal to bootstrap at all.
existing_toolkit_qualifier() {
  local region="$1"
  local profile="$2"
  local value

  value="$(aws cloudformation describe-stacks \
    --stack-name "$DEFAULT_TOOLKIT_STACK" \
    --region "$region" \
    --profile "$profile" \
    --query "Stacks[0].Parameters[?ParameterKey=='Qualifier'].ParameterValue | [0]" \
    --output text 2>/dev/null)" || return 0

  case "$value" in
    "")
      # No stack, or an answer we could not read.
      return 0
      ;;
    None)
      # describe-stacks prints the literal "None" for a null result: the stack
      # exists but declares no Qualifier parameter. Pre-qualifier bootstrap
      # templates look like that, and they are the default qualifier, so report
      # it as such rather than as an absent stack.
      printf '%s\n' "$DEFAULT_QUALIFIER"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

# Refuse to bootstrap an account whose CDKToolkit stack belongs to a different
# qualifier.
#
# `cdk bootstrap` with no --toolkit-stack-name updates CDKToolkit in place. If
# that stack was created for another qualifier, the update renames its staging
# roles and bucket from cdk-<theirs>-* to cdk-hnb659fds-* — deleting the roles
# every deployment made under that qualifier depends on. This is the direction
# that actually bites in this PoC: upstream PetAdoptions carries its own
# qualifier, so ours is the run that would clobber theirs.
assert_toolkit_not_foreign() {
  local label="$1"
  local account_id="$2"
  local region="$3"
  local profile="$4"

  local found
  found="$(existing_toolkit_qualifier "$region" "$profile")"

  # CDK's own bootstrap template derives the staging bucket's name from the
  # QUALIFIER, not from the stack name:
  # StagingBucket.BucketName = cdk-${Qualifier}-assets-${AWS::AccountId}-${AWS::Region}.
  # Same formula here, because the refusal message below has to name the exact
  # bucket a fresh toolkit stack for the default qualifier would collide with.
  local staging_bucket="cdk-${DEFAULT_QUALIFIER}-assets-${account_id}-${region}"

  if [[ -z "$found" ]]; then
    echo "    no existing ${DEFAULT_TOOLKIT_STACK} stack — bootstrapping fresh"
    return 0
  fi

  if [[ "$found" == "$DEFAULT_QUALIFIER" ]]; then
    echo "    existing ${DEFAULT_TOOLKIT_STACK} stack uses qualifier '${found}' — safe to update"
    return 0
  fi

  cat >&2 <<EOF

ERROR: refusing to bootstrap ${label} — its ${DEFAULT_TOOLKIT_STACK} stack belongs to another qualifier.

  Account : ${account_id} (${region}, profile ${profile})
  Stack   : ${DEFAULT_TOOLKIT_STACK}
  Found   : qualifier '${found}'
  Wanted  : qualifier '${DEFAULT_QUALIFIER}' (this repo's apps)

  Bootstrapping without --toolkit-stack-name would UPDATE that stack in place and
  swap its staging resources from cdk-${found}-* to cdk-${DEFAULT_QUALIFIER}-*.
  The IAM roles and asset bucket that every deployment made under qualifier
  '${found}' depends on would be deleted, and those deployments would then fail
  with a missing /cdk-bootstrap/${found}/version parameter or a vanished
  cdk-${found}-* role.

  Two qualifiers can coexist permanently: CDK keeps one toolkit stack per
  qualifier. Leave '${found}' where it is and give the default qualifier a
  toolkit stack of its own instead — TWO steps, in this order.

  STEP 1 — clear the orphaned staging bucket, if there is one.

  CDK names that bucket from the QUALIFIER rather than from the stack name
  (StagingBucket.BucketName is cdk-<qualifier>-assets-<account>-<region>), and it
  is the only bootstrap resource carrying DeletionPolicy: Retain. So a bucket left
  behind by an earlier bootstrap of '${DEFAULT_QUALIFIER}' in this account outlives
  the stack that created it, a fresh CDKToolkitDefault derives the very same name,
  and step 2 dies with:

    ${staging_bucket} already exists (AlreadyExists)

  Check whether it exists, and whether it is EMPTY:

    aws s3api head-bucket --bucket ${staging_bucket} \\
      --profile ${profile} --region ${region}

    aws s3api list-objects-v2 --bucket ${staging_bucket} --max-items 1 \\
      --profile ${profile} --region ${region}

  A 404 from head-bucket means there is nothing to clear — go straight to step 2.
  If the bucket exists and list-objects-v2 reports no Contents, it is empty and
  safe to delete:

    aws s3 rb s3://${staging_bucket} \\
      --profile ${profile} --region ${region}

  If it is NOT empty, STOP — do not delete it. Its objects are published CDK
  assets, and a deployed stack references them by key, so removing them breaks
  that stack's next update and its rollback. A non-empty bucket usually also means
  a live toolkit stack still owns it, which would mean '${DEFAULT_QUALIFIER}' is
  already bootstrapped here and the problem is a different one. Find the owner
  before touching anything:

    aws s3api get-bucket-tagging --bucket ${staging_bucket} \\
      --profile ${profile} --region ${region}

  (the aws:cloudformation:stack-name tag names the stack that owns it).

  STEP 2 — bootstrap the default qualifier into a stack of its own:

    cdk bootstrap aws://${account_id}/${region} --profile ${profile} \\
      --qualifier ${DEFAULT_QUALIFIER} \\
      --toolkit-stack-name CDKToolkitDefault

  That is what recovered this PoC's backend account. Nothing else has to change:
  --toolkit-stack-name only decides which stack owns the staging resources, and
  \`cdk deploy\` finds them through /cdk-bootstrap/${DEFAULT_QUALIFIER}/version and the
  cdk-${DEFAULT_QUALIFIER}-* role names, not through a stack name.

  Then re-run this script with --account for the remaining accounts.

  If instead '${found}' is stale and nothing depends on it, delete the
  ${DEFAULT_TOOLKIT_STACK} stack yourself and re-run. This script will not.

  Long form: docs/deployment.md#troubleshooting-two-cdk-toolkit-stacks-in-one-account

EOF
  return 99
}

bootstrap_account() {
  local label="$1"
  local account_id="$2"
  local region="$3"
  local profile="$4"

  echo ">>> Bootstrapping ${label}: aws://${account_id}/${region} (profile: ${profile})"

  # Read the existing toolkit stack before writing to it (Requirement 15.1).
  assert_toolkit_not_foreign "$label" "$account_id" "$region" "$profile" || exit 99

  # --qualifier is passed explicitly, and that is what makes this command a real
  # repair rather than a claim of one. `cdk bootstrap` with no --qualifier INHERITS
  # the existing stack's Qualifier parameter, so running it against an account
  # whose CDKToolkit has been flipped to another qualifier re-bootstraps THAT
  # qualifier and reports "✅ bootstrapped (no changes)" while
  # /cdk-bootstrap/${DEFAULT_QUALIFIER}/version stays absent. Same bug class as
  # BuildTimeoutMinutes in workload/backend/deploy/deploy-upstream.sh: a parameter
  # you do not pass is inherited, so the fix is a no-op precisely where it is
  # needed.
  #
  # The refusal above only guards the case where the existing stack is READABLE.
  # existing_toolkit_qualifier deliberately fails open — an unreadable
  # describe-stacks must never become a refusal to bootstrap — and that fail-open
  # path lands right here. The explicit qualifier is what stops it re-bootstrapping
  # a flipped stack under someone else's qualifier and calling it success.
  cdk bootstrap "aws://${account_id}/${region}" --profile "$profile" \
    --qualifier "$DEFAULT_QUALIFIER"
  echo ""
}

# ─── Execute ─────────────────────────────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  AI-Ops PoC — CDK Bootstrap                                      ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

case "${ONLY_ACCOUNT}" in
  "")
    bootstrap_account "Backend (BE)"  "$BE_ACCOUNT"  "$BE_REGION"  "$BE_PROFILE"
    bootstrap_account "Frontend (FE)" "$FE_ACCOUNT"  "$FE_REGION"  "$FE_PROFILE"
    bootstrap_account "Ops (OPS)"     "$OPS_ACCOUNT" "$OPS_REGION" "$OPS_PROFILE"
    ;;
  be|backend)
    bootstrap_account "Backend (BE)" "$BE_ACCOUNT" "$BE_REGION" "$BE_PROFILE"
    ;;
  fe|frontend)
    bootstrap_account "Frontend (FE)" "$FE_ACCOUNT" "$FE_REGION" "$FE_PROFILE"
    ;;
  ops|monitoring)
    bootstrap_account "Ops (OPS)" "$OPS_ACCOUNT" "$OPS_REGION" "$OPS_PROFILE"
    ;;
  *)
    echo "ERROR: Unknown account '${ONLY_ACCOUNT}'. Use: be, fe, or ops." >&2
    exit 1
    ;;
esac

echo ">>> Bootstrap complete."
