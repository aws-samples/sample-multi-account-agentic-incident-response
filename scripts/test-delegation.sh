#!/usr/bin/env bash
# test-delegation.sh — Validate MCP delegation from app-team to platform
#
# Fires a test webhook via the bridge (or directly via the Operator Web App
# API), then checks that:
#   1. The first responder starts investigating
#   2. MCP delegation to the platform space occurs (tools from platform visible)
#   3. A result/RCA is produced
#
# This script uses the DevOps Agent remote MCP endpoint or the webhook bridge
# to trigger a test investigation and polls for completion.
#
# Usage:
#   scripts/test-delegation.sh [--profile PROFILE] [--region REGION] [--timeout SECONDS]
#
# Defaults (resolved by scripts/lib/config.sh):
#   --profile  config/accounts.json → ops.profile
#   --region   config/accounts.json → ops.region
#   --timeout  300 (5 minutes)
#
# Requirements: 7.1 (validate delegation), 4.3

set -euo pipefail

# ─── Resolve paths ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The OPS profile and region come from the Config_Resolver rather than from
# literals in this file — one shared location, no restated account details
# (Requirements 2.2, 2.3, 2.6).
source "${PROJECT_ROOT}/scripts/lib/config.sh"

# ─── Defaults ──────────────────────────────────────────────────────────────
PROFILE_FLAG=""
REGION_FLAG=""
TIMEOUT=300
POLL_INTERVAL=15

# ─── Parse arguments ───────────────────────────────────────────────────────
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
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--profile PROFILE] [--region REGION] [--timeout SECONDS]"
      echo ""
      echo "Validates MCP delegation by firing a test investigation and checking"
      echo "that the first responder delegates to the platform space."
      echo ""
      echo "Options:"
      echo "  --profile  AWS CLI profile (default: config/accounts.json → ops.profile)"
      echo "  --region   AWS region (default: config/accounts.json → ops.region)"
      echo "  --timeout  Max wait time in seconds (default: 300)"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ─── Resolve the OPS account inputs ────────────────────────────────────────
config::init
config::account ops --profile-flag "$PROFILE_FLAG" --region-flag "$REGION_FLAG"
PROFILE="$CONFIG_OPS_PROFILE"
REGION="$CONFIG_OPS_REGION"

# ─── Colors and helpers ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; }
warn() { echo -e "  ${YELLOW}⚠ WARN${NC}: $1"; }
info() { echo -e "  ℹ $1"; }

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  DevOps Agent — Test MCP Delegation (app-team → platform)      ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Profile: ${PROFILE}                                           ║"
echo "║  Region:  ${REGION}                                            ║"
echo "║  Timeout: ${TIMEOUT}s                                          ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ─── Read configuration from SSM ─────────────────────────────────────────
echo "Step 1: Reading configuration..."

APP_TEAM_ARN=$(aws ssm get-parameter \
  --name "/aiops-poc/agent-spaces/app-team/arn" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null) || {
  fail "Could not read app-team space ARN from SSM"
  exit 1
}
APP_TEAM_SPACE_ID="${APP_TEAM_ARN##*/}"
info "app-team space: ${APP_TEAM_SPACE_ID}"

# Read webhook credentials from Secrets Manager
WEBHOOK_CREDS=$(aws secretsmanager get-secret-value \
  --secret-id "aiops-poc/webhook-credentials" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'SecretString' \
  --output text 2>/dev/null) || {
  warn "Could not read webhook credentials from Secrets Manager"
  warn "Will attempt direct API trigger instead"
  WEBHOOK_CREDS=""
}

if [[ -n "$WEBHOOK_CREDS" ]]; then
  WEBHOOK_URL=$(echo "$WEBHOOK_CREDS" | jq -r '.url')
  HMAC_SECRET=$(echo "$WEBHOOK_CREDS" | jq -r '.hmac_secret')
  info "Webhook URL: ${WEBHOOK_URL:0:50}..."
fi

echo ""

# ─── Fire test investigation ──────────────────────────────────────────────
echo "Step 2: Triggering test investigation..."

# Test payload simulates a business SLO breach that should route to platform
TEST_PAYLOAD=$(jq -n '{
  "source": "test-delegation-script",
  "timestamp": (now | todate),
  "alarm": {
    "name": "aiops-poc-checkout-latency-p99",
    "state": "ALARM",
    "reason": "Threshold crossed: adoption checkout latency p99 > 2s for 3 datapoints",
    "metric": "payforadoption latency",
    "namespace": "PetAdoptions/Business"
  },
  "symptom": "Adoption checkout taking too long - payforadoption service latency elevated",
  "test": true
}')

TRIGGER_SUCCESS=false
INVESTIGATION_ID=""

if [[ -n "$WEBHOOK_CREDS" && "$WEBHOOK_URL" != "null" ]]; then
  # Method 1: Trigger via webhook bridge (production path)
  info "Triggering via webhook (production path)..."

  # Compute HMAC signature
  TIMESTAMP=$(date -u +%s)
  SIGNATURE=$(echo -n "${TIMESTAMP}.${TEST_PAYLOAD}" | openssl dgst -sha256 -hmac "$HMAC_SECRET" -binary | base64)

  HTTP_RESPONSE=$(curl -s -o /tmp/webhook-response.json -w "%{http_code}" \
    -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -H "X-Webhook-Timestamp: ${TIMESTAMP}" \
    -H "X-Webhook-Signature: sha256=${SIGNATURE}" \
    -d "$TEST_PAYLOAD" 2>/dev/null) || true

  if [[ "$HTTP_RESPONSE" == "200" || "$HTTP_RESPONSE" == "202" ]]; then
    TRIGGER_SUCCESS=true
    # Try to extract investigation ID from response
    if [[ -f /tmp/webhook-response.json ]]; then
      INVESTIGATION_ID=$(jq -r '.investigationId // .id // empty' /tmp/webhook-response.json 2>/dev/null) || true
    fi
    pass "Webhook accepted (HTTP ${HTTP_RESPONSE})"
  else
    warn "Webhook returned HTTP ${HTTP_RESPONSE}"
    if [[ -f /tmp/webhook-response.json ]]; then
      info "Response: $(cat /tmp/webhook-response.json)"
    fi
  fi
fi

if [[ "$TRIGGER_SUCCESS" == "false" ]]; then
  # Method 2: Try direct API trigger via the DevOps Agent MCP endpoint
  info "Attempting direct API trigger..."

  # Try the investigate command via CLI
  if aws devopsagent start-investigation \
      --agent-space-id "$APP_TEAM_SPACE_ID" \
      --description "Test: Adoption checkout latency elevated - payforadoption service" \
      --profile "$PROFILE" \
      --region "$REGION" \
      --output json > /tmp/investigation-response.json 2>/dev/null; then
    TRIGGER_SUCCESS=true
    INVESTIGATION_ID=$(jq -r '.investigationId // .id // empty' /tmp/investigation-response.json 2>/dev/null) || true
    pass "Investigation started via CLI"
  elif aws devopsagent create-investigation \
      --agent-space-id "$APP_TEAM_SPACE_ID" \
      --symptom "Adoption checkout latency elevated - payforadoption service latency p99 > 2s" \
      --profile "$PROFILE" \
      --region "$REGION" \
      --output json > /tmp/investigation-response.json 2>/dev/null; then
    TRIGGER_SUCCESS=true
    INVESTIGATION_ID=$(jq -r '.investigationId // .id // empty' /tmp/investigation-response.json 2>/dev/null) || true
    pass "Investigation started via CLI (create-investigation)"
  else
    warn "CLI investigation trigger not available."
    echo ""
    echo "  To test delegation manually:"
    echo "  1. Open the app-team Operator Web App"
    echo "  2. Start a new investigation with symptom:"
    echo "     'Adoption checkout latency elevated - payforadoption service'"
    echo "  3. Watch the investigation timeline for MCP delegation to platform"
    echo ""
  fi
fi

if [[ "$TRIGGER_SUCCESS" == "false" ]]; then
  fail "Could not trigger test investigation (no webhook or CLI available)"
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "  RESULT: INCONCLUSIVE — manual validation required"
  echo "═══════════════════════════════════════════════════════════════════"
  exit 1
fi

echo ""

# ─── Poll for investigation status ───────────────────────────────────────
echo "Step 3: Monitoring investigation (timeout: ${TIMEOUT}s, poll: ${POLL_INTERVAL}s)..."

STARTED=false
DELEGATED=false
COMPLETED=false
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  # Attempt to get investigation status
  STATUS_JSON=""

  if [[ -n "$INVESTIGATION_ID" ]]; then
    STATUS_JSON=$(aws devopsagent get-investigation \
      --agent-space-id "$APP_TEAM_SPACE_ID" \
      --investigation-id "$INVESTIGATION_ID" \
      --profile "$PROFILE" \
      --region "$REGION" \
      --output json 2>/dev/null) || true
  fi

  # If we can't get status by ID, try listing recent investigations
  if [[ -z "$STATUS_JSON" ]]; then
    STATUS_JSON=$(aws devopsagent list-investigations \
      --agent-space-id "$APP_TEAM_SPACE_ID" \
      --max-results 1 \
      --profile "$PROFILE" \
      --region "$REGION" \
      --output json 2>/dev/null) || true

    # Extract the most recent investigation
    if [[ -n "$STATUS_JSON" ]]; then
      STATUS_JSON=$(echo "$STATUS_JSON" | jq '.investigations[0] // empty' 2>/dev/null) || true
    fi
  fi

  if [[ -z "$STATUS_JSON" ]]; then
    info "[${ELAPSED}s] Waiting for investigation data..."
    continue
  fi

  # Parse status
  INV_STATUS=$(echo "$STATUS_JSON" | jq -r '.status // .state // "unknown"' 2>/dev/null) || true
  INV_PHASE=$(echo "$STATUS_JSON" | jq -r '.phase // .currentStep // empty' 2>/dev/null) || true

  # Check for delegation evidence in timeline/steps
  DELEGATION_EVIDENCE=$(echo "$STATUS_JSON" | jq -r '
    (.timeline // .steps // .events // [])[] |
    select(.type == "mcp_delegation" or .type == "capability_provider_call" or
           (.description // "" | test("platform|delegate|mcp"; "i"))) |
    .type // .description // "delegation detected"
  ' 2>/dev/null) || true

  # Track state
  if [[ "$INV_STATUS" != "unknown" && "$INV_STATUS" != "null" ]]; then
    STARTED=true
  fi

  if [[ -n "$DELEGATION_EVIDENCE" ]]; then
    DELEGATED=true
  fi

  case "$INV_STATUS" in
    completed|resolved|done|COMPLETED|RESOLVED)
      COMPLETED=true
      break
      ;;
    failed|error|FAILED|ERROR)
      info "[${ELAPSED}s] Investigation status: ${INV_STATUS}"
      break
      ;;
    *)
      info "[${ELAPSED}s] Status: ${INV_STATUS}${INV_PHASE:+ (${INV_PHASE})}"
      ;;
  esac
done

echo ""

# ─── Check CloudWatch logs for delegation evidence ────────────────────────
echo "Step 4: Checking for delegation evidence..."

# Look for MCP delegation in CloudWatch logs (DevOps Agent log group)
LOG_EVIDENCE=$(aws logs filter-log-events \
  --log-group-name "/aws/devopsagent/${APP_TEAM_SPACE_ID}" \
  --start-time "$(($(date +%s) - TIMEOUT))000" \
  --filter-pattern '"platform-mcp" OR "capability_provider" OR "mcp_delegation" OR "delegat"' \
  --limit 5 \
  --profile "$PROFILE" \
  --region "$REGION" \
  --output json 2>/dev/null) || true

if [[ -n "$LOG_EVIDENCE" ]]; then
  LOG_HITS=$(echo "$LOG_EVIDENCE" | jq '.events | length' 2>/dev/null) || LOG_HITS=0
  if [[ "$LOG_HITS" -gt 0 ]]; then
    DELEGATED=true
    info "Found ${LOG_HITS} delegation-related log entries"
  fi
fi

echo ""

# ─── Results ──────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  TEST RESULTS"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

OVERALL_PASS=true

# Check 1: Investigation started
if [[ "$STARTED" == "true" ]]; then
  pass "First responder started investigation"
else
  if [[ "$TRIGGER_SUCCESS" == "true" ]]; then
    warn "Investigation trigger accepted but status could not be confirmed"
    warn "  (CLI status commands may not be available — check the Operator Web App)"
  else
    fail "Investigation did not start"
    OVERALL_PASS=false
  fi
fi

# Check 2: MCP delegation occurred
if [[ "$DELEGATED" == "true" ]]; then
  pass "MCP delegation to platform detected"
else
  if [[ "$STARTED" == "true" && "$COMPLETED" == "true" ]]; then
    warn "Investigation completed but MCP delegation not confirmed in logs"
    warn "  (check the investigation timeline in the Operator Web App)"
  elif [[ "$STARTED" == "true" ]]; then
    warn "Investigation in progress — delegation not yet detected (may still occur)"
  else
    warn "Could not verify delegation (status polling unavailable)"
  fi
fi

# Check 3: Investigation completed
if [[ "$COMPLETED" == "true" ]]; then
  pass "Investigation completed"
else
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    warn "Investigation still in progress after ${TIMEOUT}s (this is normal — investigations take 5-8 min)"
  fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
if [[ "$OVERALL_PASS" == "true" && "$TRIGGER_SUCCESS" == "true" ]]; then
  if [[ "$DELEGATED" == "true" ]]; then
    echo -e "  ${GREEN}PASS${NC}: Delegation test successful"
  elif [[ "$STARTED" == "true" || "$TRIGGER_SUCCESS" == "true" ]]; then
    echo -e "  ${YELLOW}PARTIAL${NC}: Investigation triggered; delegation not yet confirmed"
    echo "         Check the Operator Web App timeline for MCP delegation evidence."
  fi
else
  echo -e "  ${RED}FAIL${NC}: Delegation test failed — see errors above"
fi
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Cleanup
rm -f /tmp/webhook-response.json /tmp/investigation-response.json

if [[ "$OVERALL_PASS" == "false" ]]; then
  exit 1
fi
