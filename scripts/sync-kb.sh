#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-kb.sh — Ingest (sync) the Bedrock Knowledge Base corpus
#
# CloudFormation creates the Knowledge Base and its S3 data source but NEVER
# starts an ingestion job, so a freshly deployed KB is empty and kb_retrieve
# returns "No relevant passages found" for everything. This script starts an
# ingestion job for the corpus data source and polls it to completion.
#
# Idempotent: re-running re-syncs the data source (Bedrock skips unchanged
# documents), and an already-running ingestion job is detected and polled
# instead of starting a duplicate.
#
# Usage:
#   scripts/sync-kb.sh [--profile PROFILE] [--region REGION]
#
# Defaults (resolved by scripts/lib/config.sh):
#   --profile  config/accounts.json → ops.profile
#   --region   config/accounts.json → ops.region
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The OPS profile and region come from the Config_Resolver — the one shared
# location that reads config/accounts.json (Requirement 2.6). The flags below
# are passed to it so precedence stays flag > env > file > template default
# (Requirement 2.1); the former literal defaults are the template's defaults.
source "${PROJECT_ROOT}/scripts/lib/config.sh"

PROFILE_FLAG=""
REGION_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE_FLAG="$2"; shift 2 ;;
    --region)  REGION_FLAG="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--profile PROFILE] [--region REGION]"
      echo ""
      echo "Starts a Bedrock Knowledge Base ingestion job for the corpus data"
      echo "source and polls until it completes. Run after every agents/infra"
      echo "deploy (deploy-all.sh does this automatically) and after any"
      echo "change to agents/kb-corpus/."
      echo ""
      echo "Options:"
      echo "  --profile  AWS CLI profile (default: config/accounts.json → ops.profile)"
      echo "  --region   AWS region (default: config/accounts.json → ops.region)"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

config::init
config::account ops --profile-flag "$PROFILE_FLAG" --region-flag "$REGION_FLAG"
PROFILE="$CONFIG_OPS_PROFILE"
REGION="$CONFIG_OPS_REGION"

AWS=(aws --profile "$PROFILE" --region "$REGION")

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  AI-Ops PoC — Knowledge Base ingestion sync                      ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Profile: ${PROFILE}"
echo "  Region:  ${REGION}"
echo ""

# ─── Resolve KB id (SSM) and data source id (list-data-sources) ────────────
KB_ID=$("${AWS[@]}" ssm get-parameter \
  --name /aiops-poc/kb/knowledge-base-id \
  --query Parameter.Value --output text)

if [[ -z "$KB_ID" || "$KB_ID" == "None" ]]; then
  echo "ERROR: /aiops-poc/kb/knowledge-base-id not found in SSM — is agents/infra deployed?" >&2
  exit 1
fi

DS_ID=$("${AWS[@]}" bedrock-agent list-data-sources \
  --knowledge-base-id "$KB_ID" \
  --query 'dataSourceSummaries[0].dataSourceId' --output text)

if [[ -z "$DS_ID" || "$DS_ID" == "None" ]]; then
  echo "ERROR: No data source found on knowledge base ${KB_ID}." >&2
  exit 1
fi

echo "  Knowledge base: ${KB_ID}"
echo "  Data source:    ${DS_ID}"
echo ""

# ─── Reuse an in-flight job if one exists, else start a new one ─────────────
JOB_ID=$("${AWS[@]}" bedrock-agent list-ingestion-jobs \
  --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --query 'ingestionJobSummaries[?status==`STARTING` || status==`IN_PROGRESS`] | [0].ingestionJobId' \
  --output text)

if [[ -n "$JOB_ID" && "$JOB_ID" != "None" ]]; then
  echo ">>> Ingestion job ${JOB_ID} already in progress — polling it instead."
else
  JOB_ID=$("${AWS[@]}" bedrock-agent start-ingestion-job \
    --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
    --description "sync-kb.sh corpus sync" \
    --query 'ingestionJob.ingestionJobId' --output text)
  echo ">>> Started ingestion job ${JOB_ID}."
fi

# ─── Poll to completion ─────────────────────────────────────────────────────
while true; do
  STATUS=$("${AWS[@]}" bedrock-agent get-ingestion-job \
    --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
    --ingestion-job-id "$JOB_ID" \
    --query 'ingestionJob.status' --output text)
  echo "    status: ${STATUS}"
  case "$STATUS" in
    COMPLETE|FAILED|STOPPED) break ;;
  esac
  sleep 15
done

"${AWS[@]}" bedrock-agent get-ingestion-job \
  --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --ingestion-job-id "$JOB_ID" \
  --query 'ingestionJob.{status:status,statistics:statistics,failureReasons:failureReasons}' \
  --output json

if [[ "$STATUS" != "COMPLETE" ]]; then
  echo ""
  echo "ERROR: Ingestion job ${JOB_ID} finished with status ${STATUS} (see failureReasons above)." >&2
  exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  KB ingestion complete — knowledge base ${KB_ID} is in sync."
echo ""
