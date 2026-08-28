#!/usr/bin/env bash
# set-webhook-secret.sh — Store the DevOps Agent webhook credentials in Secrets Manager.
#
# The generic webhook for the app-team Agent Space is created manually in
# the Operator Web App (webhook creation is NOT exposed via CloudFormation
# or the aws devopsagent CLI as of 2025-06).
#
# This script prompts for the URL and HMAC signing secret, then writes them
# to Secrets Manager as aiops-poc/webhook-credentials in the OPS account.
# The webhook bridge Lambda reads this secret at runtime.
#
# Usage:
#   ./set-webhook-secret.sh [--profile PROFILE] [--region REGION]
#
# Defaults (resolved by scripts/lib/config.sh):
#   --profile  config/accounts.json → ops.profile
#   --region   config/accounts.json → ops.region

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The OPS profile and region come from the Config_Resolver rather than from
# literals in this file — one shared location, no restated account details
# (Requirements 2.2, 2.3, 2.6).
source "${PROJECT_ROOT}/scripts/lib/config.sh"

SECRET_NAME="aiops-poc/webhook-credentials"
PROFILE_FLAG=""
REGION_FLAG=""

# ─── Parse arguments ────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE_FLAG="$2"
      shift 2
      ;;
    --region)
      REGION_FLAG="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--profile PROFILE] [--region REGION]"
      echo ""
      echo "Stores the DevOps Agent webhook URL and HMAC secret in Secrets Manager."
      echo ""
      echo "Options:"
      echo "  --profile  AWS CLI profile (default: config/accounts.json → ops.profile)"
      echo "  --region   AWS region (default: config/accounts.json → ops.region)"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Run $0 --help for usage." >&2
      exit 1
      ;;
  esac
done

# ─── Resolve the OPS account inputs ────────────────────────────────────────

config::init
config::account ops --profile-flag "$PROFILE_FLAG" --region-flag "$REGION_FLAG"
PROFILE="$CONFIG_OPS_PROFILE"
REGION="$CONFIG_OPS_REGION"

# ─── Prompt for credentials ────────────────────────────────────────────────

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  DevOps Agent — Webhook Credential Setup                        ║"
echo "╠═══════════════════════════════════════════════════════════════════╣"
echo "║  Store the generic webhook credentials from the Operator Web    ║"
echo "║  App into Secrets Manager (${SECRET_NAME}).   ║"
echo "║                                                                 ║"
echo "║  Profile: ${PROFILE}                                            ║"
echo "║  Region:  ${REGION}                                             ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

read -rp "Webhook URL (from Operator Web App): " WEBHOOK_URL
if [[ -z "${WEBHOOK_URL}" ]]; then
  echo "ERROR: Webhook URL cannot be empty." >&2
  exit 1
fi

read -rp "HMAC signing secret (from Operator Web App): " HMAC_SECRET
if [[ -z "${HMAC_SECRET}" ]]; then
  echo "ERROR: HMAC signing secret cannot be empty." >&2
  exit 1
fi

# ─── Build JSON payload ────────────────────────────────────────────────────

# Keys MUST be webhook_url + hmac_secret — the webhook bridge Lambda
# (agents/infra/lambda/webhook-bridge/handler.py) reads exactly these.
SECRET_VALUE=$(jq -n \
  --arg webhook_url "${WEBHOOK_URL}" \
  --arg hmac_secret "${HMAC_SECRET}" \
  '{"webhook_url": $webhook_url, "hmac_secret": $hmac_secret}')

# ─── Write to Secrets Manager ──────────────────────────────────────────────

echo ""
echo "Writing credentials to Secrets Manager..."

# Check if secret already exists
if aws secretsmanager describe-secret \
    --secret-id "${SECRET_NAME}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    >/dev/null 2>&1; then
  # Update existing secret
  aws secretsmanager put-secret-value \
    --secret-id "${SECRET_NAME}" \
    --secret-string "${SECRET_VALUE}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --output text --query 'Name'
  echo "✓ Updated existing secret: ${SECRET_NAME}"
else
  # Create new secret
  aws secretsmanager create-secret \
    --name "${SECRET_NAME}" \
    --description "DevOps Agent app-team webhook URL and HMAC signing secret (set by set-webhook-secret.sh)" \
    --secret-string "${SECRET_VALUE}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --output text --query 'Name'
  echo "✓ Created secret: ${SECRET_NAME}"
fi

echo ""
echo "Done. The webhook bridge Lambda will pick up the credentials on next"
echo "invocation (no redeploy needed)."
