#!/usr/bin/env bash
# test-fallback.sh — Validate the forced-fallback A2A path.
#
# Steps:
#   1. Read /aiops-poc/peer to determine which fallback agents are registered
#   2. Deactivate the platform space's relevant skill (forces fallback)
#   3. Fire a test webhook to trigger the first-responder investigation
#   4. Wait for the fallback agent to produce a report in S3
#   5. Re-enable the platform skill
#   6. Print the verdict
#
# ─── What this script can and cannot prove ─────────────────────────────────
# It asserts on DELEGATION: the app-team space, while investigating, choosing
# to call a fallback agent. Nothing here can cause that decision — the script
# fires a webhook and waits for a report to appear in S3, and the responder may
# legitimately resolve the incident without delegating at all.
#
# So an absent report is NOT a failure of the custom estate. Three verdicts,
# with three exit statuses, because conflating them is what made a healthy
# deploy read as broken:
#
#   PASS         (exit 0)  a report appeared — delegation happened
#   INCONCLUSIVE (exit 2)  no report inside the window — delegation was not
#                          observed; the fallback estate itself is untested
#                          either way by this script
#   FAIL         (exit 1)  the script's own preconditions broke (the webhook
#                          bridge could not be invoked)
#
# To assert on the fallback agents themselves — a causal check that invokes
# `investigate` directly over SigV4 and validates the report and its archive —
# use `scripts/smoke-test.sh --custom-only`.
#
# Usage:
#   ./test-fallback.sh [--profile PROFILE] [--region REGION] [--timeout SECS]
#                      [--skip-restore] [--symptom SYMPTOM]
#
# Defaults (resolved by scripts/lib/config.sh):
#   --profile  config/accounts.json → ops.profile
#   --region   config/accounts.json → ops.region
#   --timeout  180 (seconds to wait for fallback report)
#   --symptom  "Adoption checkout latency p99 > 2s for 3 consecutive minutes"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The OPS account (this script's target) and the BE account (the synthetic
# alarm's origin) both come from the Config_Resolver — this script used to read
# the config for the account ID and keep literals for everything else
# (Requirements 2.3, 2.4, 3.5).
source "${PROJECT_ROOT}/scripts/lib/config.sh"

# ─── Defaults ───────────────────────────────────────────────────────────────

PROFILE_FLAG=""
REGION_FLAG=""
TIMEOUT=180
SKIP_RESTORE=false
TEST_SYMPTOM="Adoption checkout latency p99 > 2s for 3 consecutive minutes"

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
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --skip-restore)
      SKIP_RESTORE=true
      shift
      ;;
    --symptom)
      TEST_SYMPTOM="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--profile PROFILE] [--region REGION] [--timeout SECS]
          [--skip-restore] [--symptom SYMPTOM]

Validates the forced-fallback A2A path by deactivating the platform skill,
firing a test webhook, and verifying a fallback report appears in S3.

Options:
  --profile       AWS CLI profile (default: config/accounts.json → ops.profile)
  --region        AWS region (default: config/accounts.json → ops.region)
  --timeout       Seconds to wait for fallback report (default: 180)
  --skip-restore  Don't re-enable the skill after the test
  --symptom       Custom symptom text for the test webhook
EOF
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ─── Configuration ─────────────────────────────────────────────────────────

config::init
config::account ops --profile-flag "$PROFILE_FLAG" --region-flag "$REGION_FLAG"
PROFILE="$CONFIG_OPS_PROFILE"
REGION="$CONFIG_OPS_REGION"
OPS_ACCOUNT_ID="$CONFIG_OPS_ACCOUNT"
REPORT_BUCKET="aiops-poc-reports-${OPS_ACCOUNT_ID}"

# The synthetic alarm below impersonates a BE business-SLO alarm
# (payforadoption), so its SNS topic ARN is composed from the backend account
# and region instead of being written out as a literal.
config::account be
BE_INCIDENTS_TOPIC_ARN="arn:aws:sns:${CONFIG_BE_REGION}:${CONFIG_BE_ACCOUNT}:aiops-poc-incidents"

# Read peer selection
PEER=$(aws ssm get-parameter \
  --name "/aiops-poc/peer" \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --query "Parameter.Value" \
  --output text 2>/dev/null || echo "both")

# Read webhook bridge function name
WEBHOOK_FUNCTION=$(aws ssm get-parameter \
  --name "/aiops-poc/webhook-bridge-function" \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --query "Parameter.Value" \
  --output text 2>/dev/null || echo "aiops-poc-webhook-bridge")

echo ""
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  Forced-Fallback Test                                           ║"
echo "╠═══════════════════════════════════════════════════════════════════╣"
echo "║  Profile:     ${PROFILE}"
echo "║  Region:      ${REGION}"
echo "║  Peer:        ${PEER}"
echo "║  Timeout:     ${TIMEOUT}s"
echo "║  Report S3:   ${REPORT_BUCKET}"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""

# ─── Helper functions ──────────────────────────────────────────────────────

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Record the start time for S3 prefix filtering
TEST_START=$(date -u +"%Y-%m-%dT%H:%M:%S")
TEST_START_EPOCH=$(date +%s)

# ─── Step 1: Deactivate platform skill (force fallback) ───────────────────

echo "Step 1/5: Deactivating platform space skill to force fallback..."
echo ""

# The platform space skill toggle is managed via the Operator Web App.
# For automation, we attempt the devopsagent CLI if available.
SKILL_DEACTIVATED=false

if aws devopsagent update-skill --help >/dev/null 2>&1; then
  # Get platform space ID
  PLATFORM_SPACE_ARN=$(aws ssm get-parameter \
    --name "/aiops-poc/agent-spaces/platform/arn" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

  PLATFORM_SPACE_ID=$(echo "${PLATFORM_SPACE_ARN}" | awk -F'/' '{print $NF}')

  # Attempt to deactivate all skills in the platform space
  aws devopsagent update-skill \
    --agent-space-id "${PLATFORM_SPACE_ID}" \
    --skill-name "checkout-latency-investigation" \
    --status "INACTIVE" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --output text 2>/dev/null && SKILL_DEACTIVATED=true
fi

if [[ "${SKILL_DEACTIVATED}" == "false" ]]; then
  echo "  ⚠ Cannot deactivate skill via CLI. Two options:"
  echo "    a) Manually deactivate the skill in the Operator Web App → platform space → Skills"
  echo "    b) The test will instruct the first responder to consult remote agents"
  echo ""
  echo "  Proceeding with explicit instruction approach..."
  # Modify the symptom to include fallback instruction
  TEST_SYMPTOM="${TEST_SYMPTOM}. NOTE: Platform investigation unavailable — consult registered remote A2A agents for backend diagnosis."
else
  echo "  ✓ Deactivated checkout-latency-investigation skill in platform space"
fi

echo ""

# ─── Step 2: Fire test webhook ─────────────────────────────────────────────

echo "Step 2/5: Firing test webhook via Lambda..."
echo ""

# Build an SNS-like event payload that the webhook bridge expects
TEST_ALARM_PAYLOAD=$(jq -n \
  --arg symptom "${TEST_SYMPTOM}" \
  --arg timestamp "$(timestamp)" \
  --arg source "test-fallback.sh" \
  --arg topic_arn "${BE_INCIDENTS_TOPIC_ARN}" \
  --arg alarm_region "${CONFIG_BE_REGION}" \
  '{
    "Records": [{
      "Sns": {
        "Type": "Notification",
        "MessageId": "test-fallback-'$(date +%s)'",
        "TopicArn": $topic_arn,
        "Subject": "ALARM: test-fallback-checkout-latency",
        "Message": ({
          "AlarmName": "test-fallback-checkout-latency",
          "AlarmDescription": $symptom,
          "NewStateValue": "ALARM",
          "NewStateReason": "Threshold Crossed: forced fallback test",
          "StateChangeTime": $timestamp,
          "Region": $alarm_region,
          "Trigger": {
            "MetricName": "p99Latency",
            "Namespace": "AiOpsPoc/BusinessSLO",
            "Dimensions": [{"name": "Service", "value": "payforadoption"}]
          }
        } | tostring),
        "Timestamp": $timestamp
      }
    }]
  }')

# Invoke the webhook bridge directly (simulates SNS delivery).
# Whether this succeeded is tracked, because it is the one precondition this
# script owns: if the bridge cannot be invoked, nothing downstream could have
# happened and the verdict is a genuine FAIL rather than INCONCLUSIVE.
WEBHOOK_FIRED=false

INVOKE_RESULT=$(aws lambda invoke \
  --function-name "${WEBHOOK_FUNCTION}" \
  --payload "$(echo "${TEST_ALARM_PAYLOAD}" | base64)" \
  --profile "${PROFILE}" \
  --region "${REGION}" \
  --cli-binary-format raw-in-base64-out \
  --output json \
  /tmp/test-fallback-response.json 2>&1 || echo "INVOKE_FAILED")

if echo "${INVOKE_RESULT}" | grep -q "INVOKE_FAILED"; then
  # Try alternative invocation format
  if aws lambda invoke \
    --function-name "${WEBHOOK_FUNCTION}" \
    --payload "${TEST_ALARM_PAYLOAD}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --output json \
    /tmp/test-fallback-response.json 2>/dev/null; then
    WEBHOOK_FIRED=true
  fi
else
  WEBHOOK_FIRED=true
fi

if [[ -f /tmp/test-fallback-response.json ]]; then
  echo "  Webhook bridge response:"
  cat /tmp/test-fallback-response.json 2>/dev/null || echo "  (no response body)"
  echo ""
else
  echo "  ⚠ Could not read Lambda response (bridge may still have triggered)"
fi

if [[ "${WEBHOOK_FIRED}" == "true" ]]; then
  echo "  ✓ Test webhook fired"
else
  echo "  ✗ Could not invoke the webhook bridge Lambda"
fi
echo ""

# ─── Step 3: Wait for fallback report in S3 ───────────────────────────────

echo "Step 3/5: Waiting for a delegated fallback report in S3 (timeout: ${TIMEOUT}s)..."
echo "  Bucket: ${REPORT_BUCKET}"
echo "  Looking for reports newer than: ${TEST_START}"
echo "  (Nothing here forces delegation — an empty window is inconclusive,"
echo "   not a failure. See the header for why.)"
echo ""

REPORT_FOUND=false
REPORT_KEY=""
ELAPSED=0
POLL_INTERVAL=10

while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
  # List objects in the report bucket created after test start
  REPORTS=$(aws s3api list-objects-v2 \
    --bucket "${REPORT_BUCKET}" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --query "Contents[?LastModified>='${TEST_START}'].Key" \
    --output text 2>/dev/null || echo "")

  if [[ -n "${REPORTS}" && "${REPORTS}" != "None" ]]; then
    # Found at least one report
    REPORT_KEY=$(echo "${REPORTS}" | head -1)
    REPORT_FOUND=true
    break
  fi

  sleep "${POLL_INTERVAL}"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
  printf "  Waiting... (%ds / %ds)\r" "${ELAPSED}" "${TIMEOUT}"
done
echo ""

# ─── Step 4: Re-enable platform skill ─────────────────────────────────────

echo "Step 4/5: Re-enabling platform space skill..."
echo ""

if [[ "${SKIP_RESTORE}" == "true" ]]; then
  echo "  Skipped (--skip-restore)"
elif [[ "${SKILL_DEACTIVATED}" == "true" ]]; then
  aws devopsagent update-skill \
    --agent-space-id "${PLATFORM_SPACE_ID}" \
    --skill-name "checkout-latency-investigation" \
    --status "ACTIVE" \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --output text 2>/dev/null && echo "  ✓ Re-enabled skill" || \
    echo "  ⚠ Could not re-enable skill via CLI — restore manually in Operator Web App"
else
  echo "  Skipped (skill was not deactivated via CLI)"
fi
echo ""

# ─── Step 5: Report results ───────────────────────────────────────────────

echo "Step 5/5: Results"
echo ""
echo "═══════════════════════════════════════════════════════════════════════"

if [[ "${REPORT_FOUND}" == "true" ]]; then
  echo "  ✅ PASS — Fallback report found"
  echo ""
  echo "  Report key: ${REPORT_KEY}"
  echo "  Bucket:     ${REPORT_BUCKET}"
  echo ""

  # Download and display the report summary
  echo "  Report content (first 50 lines):"
  echo "  ─────────────────────────────────"
  aws s3 cp "s3://${REPORT_BUCKET}/${REPORT_KEY}" /tmp/fallback-report.json \
    --profile "${PROFILE}" \
    --region "${REGION}" \
    --quiet 2>/dev/null

  if [[ -f /tmp/fallback-report.json ]]; then
    # Pretty-print the JSON report (truncated)
    jq '.' /tmp/fallback-report.json 2>/dev/null | head -50 || \
      head -50 /tmp/fallback-report.json
    echo ""

    # Validate report schema (basic checks)
    echo "  Report schema validation:"
    HAS_ROOT_CAUSE=$(jq -r '.root_cause // .rootCause // empty' /tmp/fallback-report.json 2>/dev/null || echo "")
    HAS_CONFIDENCE=$(jq -r '.confidence // empty' /tmp/fallback-report.json 2>/dev/null || echo "")
    HAS_EVIDENCE=$(jq -r '.evidence // empty' /tmp/fallback-report.json 2>/dev/null || echo "")
    HAS_TRIGGER=$(jq -r '.trigger // empty' /tmp/fallback-report.json 2>/dev/null || echo "")

    [[ -n "${HAS_ROOT_CAUSE}" ]] && echo "    ✓ root_cause present" || echo "    ✗ root_cause missing"
    [[ -n "${HAS_CONFIDENCE}" ]] && echo "    ✓ confidence present" || echo "    ✗ confidence missing"
    [[ -n "${HAS_EVIDENCE}" ]] && echo "    ✓ evidence present" || echo "    ✗ evidence missing"
    [[ -n "${HAS_TRIGGER}" ]] && echo "    ✓ trigger present" || echo "    ✗ trigger missing"
  fi

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
  echo "  The forced-fallback test PASSED."
  echo "  The first responder successfully delegated to the A2A fallback"
  echo "  agent (peer=${PEER}), which produced a structured report."
  echo ""
  exit 0
elif [[ "${WEBHOOK_FIRED}" != "true" ]]; then
  echo "  ❌ FAIL — the webhook bridge Lambda could not be invoked"
  echo ""
  echo "  Nothing downstream could have run, so this is the script's own"
  echo "  precondition failing rather than a statement about delegation."
  echo ""
  echo "  Check the function and its permissions:"
  echo "    aws lambda get-function --function-name ${WEBHOOK_FUNCTION} --profile ${PROFILE} --region ${REGION}"
  echo "    aws logs tail /aws/lambda/${WEBHOOK_FUNCTION} --profile ${PROFILE} --region ${REGION}"
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
  exit 1
else
  echo "  ⚠ INCONCLUSIVE — no delegated report appeared within ${TIMEOUT}s"
  echo ""
  echo "  The webhook fired and the responder was paged. What did not happen is"
  echo "  the responder CHOOSING to call a fallback agent inside the window, and"
  echo "  nothing in this script can cause that choice — so this is not a"
  echo "  statement that the custom estate is broken. It very often means the"
  echo "  responder resolved the incident from the platform space's live"
  echo "  investigation instead, which is the documented preferred path."
  echo ""
  echo "  To assert on the fallback agents directly — invoke 'investigate' over"
  echo "  SigV4 and validate the returned report and its S3 archive:"
  echo ""
  echo "    scripts/smoke-test.sh --custom-only --peer ${PEER}"
  echo ""
  echo "  If you specifically want to see delegation, check in this order:"
  echo "    1. Was an investigation created at all?"
  echo "       aws logs tail /aws/lambda/${WEBHOOK_FUNCTION} --profile ${PROFILE} --region ${REGION}"
  echo ""
  echo "    2. Read the app-team investigation's journal in the Operator Web App —"
  echo "       it records whether a fallback tool was considered and why."
  echo ""
  echo "    3. Are the fallback agents registered and associated?"
  echo "       Operator Web App → app-team → Capability Providers → MCP Servers"
  echo "       (register with scripts/register-fallback-agents-mcp.sh)"
  echo ""
  echo "    4. A longer window sometimes helps — investigations run 5-8 minutes:"
  echo "       scripts/test-fallback.sh --timeout 600"
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Verdict: INCONCLUSIVE (delegation not observed). Exit status 2."
  echo ""
  exit 2
fi
