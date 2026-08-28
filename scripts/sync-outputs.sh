#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-outputs.sh — Copy cross-account values between accounts via SSM
#
# Synchronizes outputs that one account produces and another account needs:
#   1.  Petsite URL parameters:  FE ← BE (backend service endpoints)
#   1b. PrivateLink service name: FE ← BE
#   2.  Agent Space ARNs:        FE + BE ← OPS
#
# REMOVED: a third section, `--section roles`, copied
# /aiops-poc/agents/{backend-devops-agent,backend-kb-agent,diagnostics-mcp}-task-role-arn
# from OPS to BE "for BE read-role trust tightening". Nothing ever published
# those parameters — AgentsInfraStack publishes /aiops-poc/agents/<name>/runtime-arn
# and /runtime-id, and creates two task roles (aiops-poc-agent-task-role,
# aiops-poc-mcp-task-role) whose ARNs it never writes to SSM. So the section
# printed three WARNs and incremented the error counter on every deploy, for a
# mechanism that no longer exists: the BE read role's trust is tightened at
# deploy time by BackendOverlayStack naming both role ARNs directly in an
# ArnEquals condition on aws:PrincipalArn, which is deterministic and needs no
# sync. Keeping the section only taught replicators that warnings here are normal.
#
# Usage:
#   scripts/sync-outputs.sh [--dry-run] [--section <urls|privatelink|arns|all>] [--help]
#
# Flags:
#   --dry-run       Show what would be synced without writing
#   --section       Sync only a specific section (urls, privatelink, arns; default: all)
#   -h, --help      Show this help
#
# Requirements: 15.2
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Every region and profile below comes from the Config_Resolver — the one
# shared location that reads config/accounts.json (Requirement 2.6).
source "${PROJECT_ROOT}/scripts/lib/config.sh"

# ─── Parse flags ─────────────────────────────────────────────────────────────
DRY_RUN=false
SECTION="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --section)  SECTION="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: scripts/sync-outputs.sh [--dry-run] [--section <urls|privatelink|arns|all>]"
      echo ""
      echo "Synchronizes cross-account values via SSM Parameter Store."
      echo ""
      echo "Sections:"
      echo "  urls         Petsite backend URL parameters: FE ← BE"
      echo "               (except searchapiurl/petlistadoptionsurl/"
      echo "               petfoodapiurl/petfoodcarturl/cleanupadoptionsurl/"
      echo "               paymentapiurl — FE-owned; and petsiteurl —"
      echo "               self-referential per account)"
      echo "  privatelink  PrivateLink endpoint service name: FE ← BE"
      echo "  arns         Agent Space ARNs: FE + BE ← OPS"
      echo "  all          All of the above (default)"
      echo ""
      echo "Flags:"
      echo "  --dry-run   Show what would be synced without writing"
      echo "  -h, --help  Show this help"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Validate ────────────────────────────────────────────────────────────────
# config::init checks jq and the config file itself, naming the missing
# prerequisite or the file to create (Requirements 3.1, 3.4).
config::init

# ─── Read config ─────────────────────────────────────────────────────────────
# One call per role sets CONFIG_<ROLE>_{ACCOUNT,REGION,PROFILE}.
config::account be
config::account fe
config::account ops

BE_REGION="$CONFIG_BE_REGION"
BE_PROFILE="$CONFIG_BE_PROFILE"

FE_REGION="$CONFIG_FE_REGION"
FE_PROFILE="$CONFIG_FE_PROFILE"

OPS_REGION="$CONFIG_OPS_REGION"
OPS_PROFILE="$CONFIG_OPS_PROFILE"

# ─── Helpers ─────────────────────────────────────────────────────────────────
ssm_get() {
  local profile="$1"
  local region="$2"
  local param_name="$3"

  aws ssm get-parameter \
    --name "$param_name" \
    --query "Parameter.Value" \
    --output text \
    --profile "$profile" \
    --region "$region" 2>/dev/null || echo ""
}

ssm_put() {
  local profile="$1"
  local region="$2"
  local param_name="$3"
  local value="$4"
  local description="${5:-Synced by ai-ops-poc sync-outputs.sh}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [DRY-RUN] Would write ${param_name} = ${value}"
    return 0
  fi

  aws ssm put-parameter \
    --name "$param_name" \
    --value "$value" \
    --type String \
    --overwrite \
    --description "$description" \
    --profile "$profile" \
    --region "$region" > /dev/null

  echo "    ✓ ${param_name}"
}

ssm_get_by_path() {
  local profile="$1"
  local region="$2"
  local path_prefix="$3"

  aws ssm get-parameters-by-path \
    --path "$path_prefix" \
    --recursive \
    --query "Parameters[*].[Name,Value]" \
    --output text \
    --profile "$profile" \
    --region "$region" 2>/dev/null || echo ""
}

# Track sync counts
SYNCED=0
ERRORS=0

sync_param() {
  local src_profile="$1"
  local src_region="$2"
  local dst_profile="$3"
  local dst_region="$4"
  local param_name="$5"
  local description="${6:-}"

  local value
  value=$(ssm_get "$src_profile" "$src_region" "$param_name")

  if [[ -z "$value" ]]; then
    echo "    WARN: ${param_name} not found in source (${src_profile}), skipping"
    ((ERRORS++)) || true
    return 0
  fi

  ssm_put "$dst_profile" "$dst_region" "$param_name" "$value" "$description"
  ((SYNCED++)) || true
}

# ─── Section 1: Petsite URL parameters (FE ← BE) ────────────────────────────
sync_urls() {
  echo "─── Section 1: Petsite URL parameters (FE ← BE) ───"
  echo ""

  # PetAdoptions stores its service URLs under /petstore/ in SSM
  # We read them from BE and write the same paths in FE so petsite can find them
  local params
  params=$(ssm_get_by_path "$BE_PROFILE" "$BE_REGION" "/petstore")

  if [[ -z "$params" ]]; then
    echo "    WARN: No parameters found under /petstore/* in BE account"
    echo "    (Upstream may not be deployed yet)"
    ((ERRORS++)) || true
    echo ""
    return 0
  fi

  while IFS=$'\t' read -r name value; do
    [[ -z "$name" ]] && continue
    # searchapiurl / petlistadoptionsurl / petfoodapiurl / petfoodcarturl /
    # cleanupadoptionsurl / paymentapiurl are OWNED BY THE FE STACK: it
    # points them at its PrivateLink interface endpoint (the BE internal
    # ALB URLs are unreachable from the FE VPC). Never overwrite them here.
    case "$name" in
      /petstore/searchapiurl|/petstore/petlistadoptionsurl|/petstore/petfoodapiurl|/petstore/petfoodcarturl|/petstore/cleanupadoptionsurl|/petstore/paymentapiurl)
        echo "    SKIP: ${name} (owned by FrontendStack — PrivateLink endpoint URL)"
        continue
        ;;
      # petsiteurl is self-referential (each account's own petsite/CloudFront
      # URL). petsite doesn't read it, but syncing would overwrite FE's value
      # with the BE CloudFront URL, which is confusing for humans and canaries.
      /petstore/petsiteurl)
        echo "    SKIP: ${name} (self-referential per account — BE value would shadow FE's)"
        continue
        ;;
    esac
    ssm_put "$FE_PROFILE" "$FE_REGION" "$name" "$value" "Petsite URL synced from BE"
    ((SYNCED++)) || true
  done <<< "$params"

  echo ""
}

# ─── Section 1b: PrivateLink service name (FE ← BE) ─────────────────────────
sync_privatelink() {
  echo "─── Section 1b: PrivateLink service name (FE ← BE) ───"
  echo ""

  # The BE overlay publishes the VPC Endpoint Service name; the FE stack
  # reads it (valueFromLookup) to create its interface endpoint, so this
  # must be synced BEFORE the FE stack deploys.
  sync_param "$BE_PROFILE" "$BE_REGION" "$FE_PROFILE" "$FE_REGION" \
    "/aiops-poc/workload/petsite-privatelink-service-name" \
    "PrivateLink endpoint service name synced from BE"

  echo ""
}

# ─── Section 2: Agent Space ARNs (FE + BE ← OPS) ────────────────────────────
sync_arns() {
  echo "─── Section 2: Agent Space ARNs (FE + BE ← OPS) ───"
  echo ""

  # The agent-spaces stack exports ARNs to /aiops-poc/agent-spaces/* in OPS
  local params
  params=$(ssm_get_by_path "$OPS_PROFILE" "$OPS_REGION" "/aiops-poc/agent-spaces")

  if [[ -z "$params" ]]; then
    echo "    WARN: No parameters found under /aiops-poc/agent-spaces/* in OPS account"
    echo "    (Agent Spaces stack may not be deployed yet)"
    ((ERRORS++)) || true
    echo ""
    return 0
  fi

  echo "  → Writing to FE account:"
  while IFS=$'\t' read -r name value; do
    [[ -z "$name" ]] && continue
    ssm_put "$FE_PROFILE" "$FE_REGION" "$name" "$value" "Agent Space ARN synced from OPS"
    ((SYNCED++)) || true
  done <<< "$params"

  echo "  → Writing to BE account:"
  while IFS=$'\t' read -r name value; do
    [[ -z "$name" ]] && continue
    ssm_put "$BE_PROFILE" "$BE_REGION" "$name" "$value" "Agent Space ARN synced from OPS"
    ((SYNCED++)) || true
  done <<< "$params"

  echo ""
}

# ─── Execute ─────────────────────────────────────────────────────────────────
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  AI-Ops PoC — Sync Cross-Account Outputs                         ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  *** DRY RUN — no parameters will be written ***"
  echo ""
fi

case "$SECTION" in
  all)
    sync_urls
    sync_privatelink
    sync_arns
    ;;
  urls)
    sync_urls
    ;;
  privatelink)
    sync_privatelink
    ;;
  arns)
    sync_arns
    ;;
  roles)
    # Named explicitly so a stale invocation gets an explanation rather than a
    # bare "unknown section". See the header for why the section is gone.
    echo "ERROR: --section roles has been removed. It synced three parameters" >&2
    echo "       that nothing publishes; the BE read-role trust it claimed to" >&2
    echo "       tighten is already pinned to both OPS task-role ARNs by" >&2
    echo "       BackendOverlayStack at deploy time. Nothing to run." >&2
    exit 1
    ;;
  *)
    echo "ERROR: Unknown section '${SECTION}'. Use: urls, privatelink, arns, or all." >&2
    exit 1
    ;;
esac

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  Sync complete."
echo "  Parameters synced: ${SYNCED}"
if [[ ${ERRORS} -gt 0 ]]; then
  echo "  Warnings/skipped:  ${ERRORS}"
fi
if [[ "$DRY_RUN" == "true" ]]; then
  echo "  (Dry run — nothing was written)"
fi
echo ""
