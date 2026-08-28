#!/usr/bin/env bash
# register-webhook.sh — Create the DevOps Agent generic webhook via the API.
#
# Automates what used to be a manual Operator Web App step:
#   1. Registers an eventChannel service (type: webhook) with the DevOps
#      Agent API: aws devops-agent register-service --service eventChannel
#   2. Associates it to the chosen Agent Space (associate-service). The
#      association response contains the GenericWebhook with the URL and
#      HMAC signing secret.
#   3. Writes the credentials to Secrets Manager (keys webhook_url +
#      hmac_secret — exactly what the webhook bridge Lambda handler reads).
#
# Dual-path routing: this script serves BOTH Agent Spaces via --space:
#   --space app-team (default)  → SSM /aiops-poc/agent-spaces/app-team/arn
#                                 secret  aiops-poc/webhook-credentials
#                                 service aiops-poc-incidents
#   --space platform            → SSM /aiops-poc/agent-spaces/platform/arn
#                                 secret  aiops-poc/platform-webhook-credentials
#                                 service aiops-poc-incidents (shared, per-space
#                                         association issues its own webhook)
#
# The webhook bridge Lambda routes aiops-poc-be-infra-* alarms to the platform
# secret and everything else to the app-team secret.
#
# eventChannel service naming: the DevOps Agent API allows exactly ONE
# eventChannel service per account (RegisterService rejects a second with
# "Event Channel service is already registered for this account"). That single
# service (aiops-poc-incidents) fans out to multiple spaces via per-space
# associations, and each association issues its OWN webhook URL + HMAC secret.
# So BOTH spaces reuse the same SERVICE_NAME (aiops-poc-incidents); the
# app-team and platform webhooks differ at the association/secret level, not
# the service level. (Discovered live 2026-07-27 against the account API.)
#
# Idempotency: if a service named ${SERVICE_NAME} already exists it is
# reused. If an eventChannel association already exists for the space, the
# script tries list-webhooks to recover the URL (the HMAC secret is only
# returned at association time; use --rotate to disassociate and re-create).
#
# Usage:
#   scripts/register-webhook.sh [--space app-team|platform] \
#                               [--profile PROFILE] [--region REGION] [--rotate]
#
# Defaults:
#   --space    app-team
#   --profile  config/accounts.json → ops.profile  (resolved by scripts/lib/config.sh)
#   --region   config/accounts.json → ops.region   (resolved by scripts/lib/config.sh)
#
# Requirements: 5.x (webhook ingestion for the managed estate)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# The OPS profile and region come from the Config_Resolver — the one shared
# location that reads config/accounts.json (Requirement 2.6). The flags are
# handed to it so precedence stays flag > env > file > template default
# (Requirement 2.1); the literal defaults this script used to carry are the
# template's declared defaults.
source "${PROJECT_ROOT}/scripts/lib/config.sh"

# ─── Defaults (flags override the resolved values) ─────────────────────────
SPACE="app-team"
PROFILE_FLAG=""
REGION_FLAG=""
ROTATE=false

# ─── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --space)   SPACE="$2"; shift 2 ;;
    --profile) PROFILE_FLAG="$2"; shift 2 ;;
    --region)  REGION_FLAG="$2"; shift 2 ;;
    --rotate)  ROTATE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--space app-team|platform] [--profile PROFILE] [--region REGION] [--rotate]"
      echo ""
      echo "Registers a DevOps Agent eventChannel webhook for the chosen space"
      echo "and stores the credentials in Secrets Manager."
      echo ""
      echo "Options:"
      echo "  --space    Target Agent Space: app-team (default) or platform"
      echo "  --profile  AWS CLI profile (default: config/accounts.json → ops.profile)"
      echo "  --region   AWS region (default: config/accounts.json → ops.region)"
      echo "  --rotate   Disassociate any existing eventChannel association and"
      echo "             re-create it (issues a new webhook URL + secret)"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ─── Resolve the OPS account inputs ────────────────────────────────────────
config::init
config::account ops --profile-flag "$PROFILE_FLAG" --region-flag "$REGION_FLAG"
PROFILE="$CONFIG_OPS_PROFILE"
REGION="$CONFIG_OPS_REGION"

# ─── Resolve per-space config (SSM param, secret name, service name) ───────
case "$SPACE" in
  app-team)
    SSM_ARN_PARAM="/aiops-poc/agent-spaces/app-team/arn"
    SECRET_NAME="aiops-poc/webhook-credentials"
    SERVICE_NAME="aiops-poc-incidents"
    SECRET_DESC="DevOps Agent app-team webhook URL and HMAC signing secret (set by register-webhook.sh)"
    ;;
  platform)
    SSM_ARN_PARAM="/aiops-poc/agent-spaces/platform/arn"
    SECRET_NAME="aiops-poc/platform-webhook-credentials"
    # Same single per-account eventChannel service as app-team (the API
    # allows only one); the platform webhook differs at the per-space
    # association + secret level, not the service level.
    SERVICE_NAME="aiops-poc-incidents"
    SECRET_DESC="DevOps Agent platform webhook URL and HMAC signing secret (set by register-webhook.sh --space platform)"
    ;;
  *)
    echo "ERROR: --space must be 'app-team' or 'platform' (got '${SPACE}')" >&2
    exit 1
    ;;
esac

for cmd in aws jq; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' is required." >&2; exit 1; }
done

aws_cmd() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  DevOps Agent — Webhook Registration (eventChannel)              ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Space:   ${SPACE}"
echo "  Profile: ${PROFILE}"
echo "  Region:  ${REGION}"
echo "  Secret:  ${SECRET_NAME}"
echo "  Service: ${SERVICE_NAME}"
echo ""

# ─── Resolve the target space ID ───────────────────────────────────────────
SPACE_ARN=$(aws_cmd ssm get-parameter \
  --name "$SSM_ARN_PARAM" \
  --query 'Parameter.Value' --output text 2>/dev/null) || {
  echo "ERROR: Could not read ${SSM_ARN_PARAM} from SSM." >&2
  echo "       Deploy the agent-spaces stack first." >&2
  exit 1
}
SPACE_ID="${SPACE_ARN##*/}"
echo "  ${SPACE} space ID: ${SPACE_ID}"
echo ""

# ─── Step 1: Register (or reuse) the eventChannel service ──────────────────
echo "Step 1: Register eventChannel service '${SERVICE_NAME}'..."

SERVICE_ID=$(aws_cmd devops-agent list-services \
  --filter-service-type eventChannel \
  --query "services[?name=='${SERVICE_NAME}'].serviceId | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ -n "$SERVICE_ID" && "$SERVICE_ID" != "None" ]]; then
  echo "  ✓ Reusing existing service: ${SERVICE_ID}"
else
  SERVICE_ID=$(aws_cmd devops-agent register-service \
    --service eventChannel \
    --name "$SERVICE_NAME" \
    --service-details '{"eventChannel": {"type": "webhook"}}' \
    --query 'serviceId' --output text)
  echo "  ✓ Registered new service: ${SERVICE_ID}"
fi

# ─── Step 2: Associate to the target space ─────────────────────────────────
echo ""
echo "Step 2: Associate service to ${SPACE} space..."

EXISTING_ASSOC_ID=$(aws_cmd devops-agent list-associations \
  --agent-space-id "$SPACE_ID" \
  --query "associations[?serviceId=='${SERVICE_ID}'].associationId | [0]" \
  --output text 2>/dev/null || echo "None")

WEBHOOK_URL=""
WEBHOOK_SECRET=""

if [[ -n "$EXISTING_ASSOC_ID" && "$EXISTING_ASSOC_ID" != "None" ]]; then
  if [[ "$ROTATE" == "true" ]]; then
    echo "  Rotating: disassociating existing association ${EXISTING_ASSOC_ID}..."
    aws_cmd devops-agent disassociate-service \
      --agent-space-id "$SPACE_ID" \
      --association-id "$EXISTING_ASSOC_ID"
    EXISTING_ASSOC_ID=""
  else
    echo "  Association already exists: ${EXISTING_ASSOC_ID}"
    echo "  Attempting to recover webhook details via list-webhooks..."
    WEBHOOK_JSON=$(aws_cmd devops-agent list-webhooks \
      --agent-space-id "$SPACE_ID" \
      --association-id "$EXISTING_ASSOC_ID" \
      --query 'webhooks[0]' --output json 2>/dev/null || echo "null")
    WEBHOOK_URL=$(echo "$WEBHOOK_JSON" | jq -r '.webhookUrl // empty')
    WEBHOOK_SECRET=$(echo "$WEBHOOK_JSON" | jq -r '.webhookSecret // empty')
    if [[ -z "$WEBHOOK_SECRET" ]]; then
      echo "" >&2
      echo "  ERROR: The HMAC secret is only returned when the association is" >&2
      echo "         created. Re-run with --rotate to issue a new webhook." >&2
      exit 1
    fi
  fi
fi

if [[ -z "$EXISTING_ASSOC_ID" || "$EXISTING_ASSOC_ID" == "None" ]]; then
  ASSOC_OUTPUT=$(aws_cmd devops-agent associate-service \
    --agent-space-id "$SPACE_ID" \
    --service-id "$SERVICE_ID" \
    --configuration '{"eventChannel": {}}' \
    --output json)

  ASSOC_ID=$(echo "$ASSOC_OUTPUT" | jq -r '.association.associationId')
  WEBHOOK_URL=$(echo "$ASSOC_OUTPUT" | jq -r '.webhook.webhookUrl // empty')
  WEBHOOK_SECRET=$(echo "$ASSOC_OUTPUT" | jq -r '.webhook.webhookSecret // empty')
  WEBHOOK_TYPE=$(echo "$ASSOC_OUTPUT" | jq -r '.webhook.webhookType // "unknown"')

  echo "  ✓ Association created: ${ASSOC_ID}"
  echo "  ✓ Webhook type: ${WEBHOOK_TYPE}"
fi

if [[ -z "$WEBHOOK_URL" || -z "$WEBHOOK_SECRET" ]]; then
  echo "ERROR: Association response did not include a webhook URL/secret." >&2
  echo "       Inspect with: aws devops-agent list-webhooks --agent-space-id ${SPACE_ID} --association-id <id> --profile ${PROFILE} --region ${REGION}" >&2
  exit 1
fi

echo "  ✓ Webhook URL: ${WEBHOOK_URL}"
echo "  ✓ HMAC secret: (captured — not displayed)"

# ─── Step 3: Write credentials to Secrets Manager ──────────────────────────
echo ""
echo "Step 3: Write credentials to Secrets Manager (${SECRET_NAME})..."

# Keys MUST be webhook_url + hmac_secret — the webhook bridge Lambda
# (agents/infra/lambda/webhook-bridge/handler.py) reads exactly these.
SECRET_VALUE=$(jq -n \
  --arg webhook_url "$WEBHOOK_URL" \
  --arg hmac_secret "$WEBHOOK_SECRET" \
  '{"webhook_url": $webhook_url, "hmac_secret": $hmac_secret}')

if aws_cmd secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  aws_cmd secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_VALUE" \
    --output text --query 'Name' >/dev/null
  echo "  ✓ Updated existing secret: ${SECRET_NAME}"
else
  aws_cmd secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "$SECRET_DESC" \
    --secret-string "$SECRET_VALUE" \
    --output text --query 'Name' >/dev/null
  echo "  ✓ Created secret: ${SECRET_NAME}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✓ Webhook registered and credentials stored (${SPACE} space)."
echo "  The webhook bridge Lambda picks up the credentials on its next"
echo "  invocation (no redeploy needed)."
echo ""
echo "  Verify end-to-end with: scripts/smoke-test.sh --managed-only"
echo "═══════════════════════════════════════════════════════════════════"
