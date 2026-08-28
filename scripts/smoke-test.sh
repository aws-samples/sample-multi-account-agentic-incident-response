#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# smoke-test.sh — End-to-end smoke test for the AI-Ops PoC
#
# Two independent estates, each asserted on something this script causes:
#
#   Managed estate — fire a test webhook via the webhook bridge Lambda and
#   confirm the first-responder investigation started in the app-team space.
#
#   Custom estate — invoke each selected fallback agent's `investigate` tool
#   directly over SigV4 (AgentCore data plane, MCP JSON-RPC) and validate the
#   report it returns, then confirm that report reached S3 at its own key.
#
# WHY THE CUSTOM CHECK INVOKES RATHER THAN POLLS. This step used to poll
# s3://<reports-bucket>/reports/<date>/ for *any* new object and call a
# 600-second miss a FAILURE of the custom estate. Nothing in the script caused
# an agent to run, so the check depended on the app-team space choosing to
# delegate during an unrelated investigation — and reported failure for
# something it never triggered. Invoking `investigate` directly makes the
# assertion causal: the script gets a report back or it does not, and because
# `archive_to_s3()` keys the object as reports/<date>/<report_id>.json, the
# archive is then checked at an exact key derived from the report just
# returned, not guessed from a timestamp window.
#
# For the delegation path — the app-team space *choosing* to call a fallback
# agent — see scripts/test-fallback.sh, which cannot cause that decision and
# so reports an unobserved delegation as INCONCLUSIVE rather than FAILED.
#
# NOTE on the two tools' argument names: the devops agent's `investigate`
# takes `symptom`, the KB agent's takes `question`. Both are live MCP tool
# schemas, so neither is renamed here — the argument name is read off
# tools/list per agent instead.
#
# Usage:
#   scripts/smoke-test.sh [flags]
#
# Flags:
#   --managed-only        Only test the managed estate path (webhook → investigation)
#   --custom-only         Only test the custom estate (invoke the fallback agents)
#   --peer <devops|kb|both>
#                         Which fallback agents the custom estate check invokes
#                         (default: /aiops-poc/peer in SSM, else both). Each
#                         agent invoked costs one model call of 5-8 minutes.
#   --timeout <seconds>   Override default timeout (managed: 300s, custom: 600s)
#   --profile <name>      AWS profile for the OPS account
#                         (default: config/accounts.json → ops.profile)
#   -h, --help            Show this help
#
# Requirements: 5.3 (test webhook confirms investigation), 15.4 (smoke-test validates the path)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The OPS account, region and profile come from the Config_Resolver — this
# script used to read the config and then keep its own literals as fallbacks
# (Requirements 2.3, 2.4, 3.5).
source "${PROJECT_ROOT}/scripts/lib/config.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────
PROFILE_FLAG=""
MANAGED_ONLY=false
CUSTOM_ONLY=false
TIMEOUT_OVERRIDE=""
PEER_OVERRIDE=""

# ─── Parse flags ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --managed-only) MANAGED_ONLY=true; shift ;;
    --custom-only)  CUSTOM_ONLY=true; shift ;;
    --peer)         PEER_OVERRIDE="$2"; shift 2 ;;
    --timeout)      TIMEOUT_OVERRIDE="$2"; shift 2 ;;
    --profile)      PROFILE_FLAG="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: scripts/smoke-test.sh [flags]"
      echo ""
      echo "End-to-end smoke test for the AI-Ops PoC."
      echo ""
      echo "Flags:"
      echo "  --managed-only        Only test managed estate (webhook → investigation)"
      echo "  --custom-only         Only test custom estate (invoke the fallback agents)"
      echo "  --peer <devops|kb|both>"
      echo "                        Which fallback agents to invoke"
      echo "                        (default: /aiops-poc/peer in SSM, else both)"
      echo "  --timeout <seconds>   Override default timeout"
      echo "  --profile <name>      AWS profile for OPS account"
      echo "                        (default: config/accounts.json → ops.profile)"
      echo "  -h, --help            Show this help"
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Cannot combine --managed-only and --custom-only
if [[ "$MANAGED_ONLY" == "true" ]] && [[ "$CUSTOM_ONLY" == "true" ]]; then
  echo "ERROR: Cannot specify both --managed-only and --custom-only" >&2
  exit 1
fi

# ─── Validate dependencies ──────────────────────────────────────────────────
# python3 signs the AgentCore data-plane MCP calls (botocore SigV4) — the same
# mechanism the register-*.sh scripts already use to verify these endpoints.
for cmd in aws jq python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

# ─── Read config ─────────────────────────────────────────────────────────────
# --profile wins, then AIOPS_OPS_PROFILE, then config/accounts.json, then the
# template default — which is the precedence the tangle of literal fallbacks
# above used to approximate.
config::init
config::account ops --profile-flag "$PROFILE_FLAG"
PROFILE="$CONFIG_OPS_PROFILE"
REGION="$CONFIG_OPS_REGION"

# ─── Timeouts ────────────────────────────────────────────────────────────────
MANAGED_TIMEOUT=300  # investigation creation usually takes <60s, allow up to 5 min
CUSTOM_TIMEOUT=600   # 10 minutes — per fallback-agent invocation; agents take 5-8 min
                     # and enforce their own 10-minute hard timeout internally

# ─── Unique per-run marker ───────────────────────────────────────────────────
# Embedded in the synthetic alarm name so step 2 can find the resulting
# investigation by title via the DevOps Agent API.
SMOKE_MARKER="diag-test-$(date -u +%Y%m%d%H%M%S)"
SMOKE_ALARM_NAME="checkout-latency-p99-${SMOKE_MARKER}"

# The symptom handed to the fallback agents in step 3. Both agents are
# consultation-only (no live telemetry, no mutations), so a synthetic symptom
# is a complete exercise of their path.
SMOKE_SYMPTOM="SMOKE TEST (${SMOKE_MARKER}): adoption checkout latency p99 above 2s for 3 consecutive minutes"

if [[ -n "$TIMEOUT_OVERRIDE" ]]; then
  MANAGED_TIMEOUT="$TIMEOUT_OVERRIDE"
  CUSTOM_TIMEOUT="$TIMEOUT_OVERRIDE"
fi

# ─── AWS helpers ─────────────────────────────────────────────────────────────
aws_cmd() {
  aws --profile "$PROFILE" --region "$REGION" "$@"
}

# ─── Resolve Lambda function name from SSM ───────────────────────────────────
resolve_function_name() {
  local fn_name
  fn_name=$(aws_cmd ssm get-parameter \
    --name "/aiops-poc/webhook-bridge-function" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

  if [[ -z "$fn_name" ]]; then
    # Fallback to the known deterministic name
    fn_name="aiops-poc-webhook-bridge"
  fi
  echo "$fn_name"
}

# ─── Report bucket (deterministic from design) ──────────────────────────────
resolve_report_bucket() {
  # config::account ops already resolved and validated ops.accountId; a missing
  # or placeholder value fails there, naming the JSON path (Requirement 3.2).
  echo "aiops-poc-reports-${CONFIG_OPS_ACCOUNT}"
}

# ─── Fallback agent selection (/aiops-poc/peer) ─────────────────────────────
# Same contract as register-fallback-agents-mcp.sh: whichever agents are
# registered are the ones worth invoking. bash 3.2, so the selection is a
# space-separated list, not an array of pairs.
resolve_peer() {
  if [[ -n "$PEER_OVERRIDE" ]]; then
    echo "$PEER_OVERRIDE"
    return 0
  fi
  aws_cmd ssm get-parameter --name "/aiops-poc/peer" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo "both"
}

# Map a peer selection to the SSM names of the runtimes to invoke.
agents_for_peer() {
  case "$1" in
    devops) echo "backend-devops-agent" ;;
    kb)     echo "backend-kb-agent" ;;
    both)   echo "backend-devops-agent backend-kb-agent" ;;
    *)      return 1 ;;
  esac
}

runtime_arn_for() {
  aws_cmd ssm get-parameter --name "/aiops-poc/agents/$1/runtime-arn" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo ""
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# AgentCore data-plane MCP invocation URL for a runtime ARN (SigV4-signed POST;
# JSON-RPC passthrough to the container's /mcp path).
mcp_url() {
  echo "https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/$(urlencode "$1")/invocations?qualifier=DEFAULT"
}

# ─── Resolve the app-team Agent Space ID from SSM ────────────────────────────
resolve_app_team_space_id() {
  local arn
  arn=$(aws_cmd ssm get-parameter \
    --name "/aiops-poc/agent-spaces/app-team/arn" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    echo ""
  else
    echo "${arn##*/}"
  fi
}

# ─── Validate the stored webhook URL is an Agent Space Webhook URL ──────────
# The DevOps Agent generic (Agent Space) webhook URL has the shape:
#   https://event-ai.<region>.api.aws/webhook/generic/<webhook-id>
# Anything else in the secret means the wrong thing was stored and events
# will never trigger investigations — fail loudly.
validate_webhook_secret() {
  local secret_json
  secret_json=$(aws_cmd secretsmanager get-secret-value \
    --secret-id "aiops-poc/webhook-credentials" \
    --query 'SecretString' --output text 2>/dev/null || echo "")

  if [[ -z "$secret_json" ]]; then
    echo "  ERROR: Secret aiops-poc/webhook-credentials not found or empty." >&2
    echo "         Run: scripts/register-webhook.sh" >&2
    return 1
  fi

  local url
  url=$(echo "$secret_json" | jq -r '.webhook_url // empty')
  local secret
  secret=$(echo "$secret_json" | jq -r '.hmac_secret // empty')

  if [[ -z "$url" || -z "$secret" ]]; then
    echo "  ERROR: Secret is missing webhook_url or hmac_secret keys." >&2
    echo "         Run: scripts/register-webhook.sh" >&2
    return 1
  fi

  if [[ ! "$url" =~ ^https://event-ai\.[a-z0-9-]+\.api\.aws/webhook/generic/[0-9a-f-]+$ ]]; then
    echo "  ERROR: webhook_url in the secret is NOT an Agent Space Webhook URL:" >&2
    echo "         ${url}" >&2
    echo "         Expected shape: https://event-ai.<region>.api.aws/webhook/generic/<id>" >&2
    echo "         Re-create it with: scripts/register-webhook.sh --rotate" >&2
    return 1
  fi

  echo "  OK: webhook_url has the Agent Space Webhook shape"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Fire test webhook
# ═══════════════════════════════════════════════════════════════════════════════
fire_test_webhook() {
  local fn_name="$1"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build the inner message as a realistic CloudWatch alarm notification.
  # NewStateValue MUST be "ALARM" so the bridge maps it to action="created" —
  # the Agent Space webhook only starts investigations for "created" events.
  # SMOKE_ALARM_NAME is unique per run so step 2 can find the investigation.
  # The account in AWSAccountId and in the topic ARN below is the canonical FE
  # Placeholder_Account_Id — the synthetic alarm is a petsite (frontend) alarm.
  # Nothing here asserts on the value; the bridge only echoes it into the
  # investigation payload, so it is a shape, not a target (Requirements 6.1, 6.5).
  local inner_message
  inner_message=$(jq -n \
    --arg ts "$timestamp" \
    --arg alarm "$SMOKE_ALARM_NAME" \
    '{
      AlarmName: $alarm,
      NewStateValue: "ALARM",
      NewStateReason: "SMOKE TEST: checkout latency p99 > 2s (synthetic event, safe to investigate briefly)",
      StateChangeTime: $ts,
      AWSAccountId: "222222222222",
      Region: "US East (N. Virginia)",
      Trigger: {
        Namespace: "SmokeTest",
        MetricName: "CheckoutLatencyP99",
        Dimensions: [{name: "Service", value: "petsite"}]
      }
    }' \
    | jq -c .)

  # The synthetic topic ARN carries the resolved region rather than a literal,
  # so the fixture stays internally consistent with the account it is sent to
  # (Requirements 2.3, 3.5). The account stays the canonical FE placeholder.
  local payload
  payload=$(jq -n \
    --arg ts "$timestamp" \
    --arg msg "$inner_message" \
    --arg topic_arn "arn:aws:sns:${REGION}:222222222222:smoke-test" \
    '{
      "Records": [{
        "Sns": {
          "TopicArn": $topic_arn,
          "Timestamp": $ts,
          "Message": $msg
        }
      }]
    }')

  echo "  Invoking Lambda: ${fn_name}"
  echo "  Synthetic alarm: ${SMOKE_ALARM_NAME}"
  echo "  Payload timestamp: ${timestamp}"

  # Invoke synchronously to confirm it processes correctly
  local outfile
  outfile=$(mktemp)

  local status_code
  status_code=$(aws_cmd lambda invoke \
    --function-name "$fn_name" \
    --invocation-type "RequestResponse" \
    --payload "$payload" \
    --cli-binary-format raw-in-base64-out \
    "$outfile" \
    --query "StatusCode" \
    --output text 2>/dev/null || echo "0")

  if [[ "$status_code" == "200" ]] || [[ "$status_code" == "202" ]]; then
    echo "  Lambda invoked successfully (status: ${status_code})"
    local result
    result=$(cat "$outfile" 2>/dev/null || echo "{}")
    rm -f "$outfile"
    echo "  Response: ${result}"
    return 0
  else
    # Fallback: try async Event invocation
    local async_status
    async_status=$(aws_cmd lambda invoke \
      --function-name "$fn_name" \
      --invocation-type "Event" \
      --payload "$payload" \
      --cli-binary-format raw-in-base64-out \
      /dev/null \
      --query "StatusCode" \
      --output text 2>/dev/null || echo "0")

    rm -f "$outfile"

    if [[ "$async_status" == "202" ]]; then
      echo "  Lambda invoked successfully (async, Event type)"
      return 0
    else
      echo "  ERROR: Lambda invocation failed (sync: ${status_code}, async: ${async_status})" >&2
      return 1
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Confirm first-responder investigation started (managed estate)
#
# Investigations are backlog tasks with taskType=INVESTIGATION in the DevOps
# Agent API. We poll ListBacklogTasks on the app-team space for a task whose
# title contains this run's unique marker (embedded in the alarm name by
# step 1). Previously this step grepped the webhook bridge Lambda's
# CloudWatch logs, which only proved delivery — not investigation creation.
# ═══════════════════════════════════════════════════════════════════════════════
confirm_managed_investigation() {
  local timeout="$1"
  local start_time
  start_time=$(date +%s)
  local deadline=$((start_time + timeout))

  local space_id
  space_id=$(resolve_app_team_space_id)
  if [[ -z "$space_id" ]]; then
    echo "  ERROR: Could not resolve the app-team Agent Space ID from SSM" >&2
    echo "         (parameter /aiops-poc/agent-spaces/app-team/arn)" >&2
    return 1
  fi

  echo "  Agent Space: ${space_id}"
  echo "  Marker:      ${SMOKE_MARKER}"
  echo "  Waiting up to ${timeout}s for an investigation whose title contains the marker..."
  echo "  (Polling: aws devops-agent list-backlog-tasks --filter taskType=INVESTIGATION)"

  local poll_interval=10
  local match=""

  while [[ $(date +%s) -lt $deadline ]]; do
    local tasks_json
    tasks_json=$(aws_cmd devops-agent list-backlog-tasks \
      --agent-space-id "$space_id" \
      --filter '{"taskType":["INVESTIGATION"]}' \
      --sort-field CREATED_AT \
      --order DESC \
      --limit 20 \
      --output json 2>/dev/null || echo "")

    if [[ -n "$tasks_json" ]]; then
      match=$(echo "$tasks_json" | jq -c --arg marker "$SMOKE_MARKER" \
        '[.tasks[] | select(.title | contains($marker))][0] // empty')
      if [[ -n "$match" ]]; then
        break
      fi
    fi

    local elapsed=$(( $(date +%s) - start_time ))
    printf "  ... polling (%ds / %ds)\r" "$elapsed" "$timeout"
    sleep "$poll_interval"
  done

  if [[ -n "$match" ]]; then
    echo ""
    echo "  Investigation found via DevOps Agent API:"
    echo "    Task ID: $(echo "$match" | jq -r '.taskId')"
    echo "    Title:   $(echo "$match" | jq -r '.title')"
    echo "    Status:  $(echo "$match" | jq -r '.status')"
    echo "    Created: $(echo "$match" | jq -r '.createdAt')"
    return 0
  else
    echo ""
    echo "  TIMEOUT: No investigation with marker '${SMOKE_MARKER}' found within ${timeout}s"
    echo "  Check webhook delivery in the bridge Lambda logs and the app-team"
    echo "  space's Webhooks tab in the DevOps Agent web app."
    return 1
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Invoke the fallback agents' `investigate` tool (custom estate)
#
# SigV4-signed MCP JSON-RPC against the AgentCore data plane: initialize →
# tools/list → tools/call. The argument name of the single `investigate` tool
# is read off tools/list rather than hardcoded, because the two agents disagree
# on it (`symptom` on the devops agent, `question` on the KB agent) and both
# are live tool schemas that a model reads for itself — renaming either to
# make this script simpler would change a deployed contract.
#
# Prints {"argument": ..., "payload": {status, report}} on success.
# ═══════════════════════════════════════════════════════════════════════════════
mcp_investigate() {
  URL="$1" MCP_SYMPTOM="$2" MCP_TIMEOUT="$3" MCP_PROFILE="$PROFILE" MCP_REGION="$REGION" \
    python3 - <<'PYEOF'
import json, os, sys, urllib.error, urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

url = os.environ["URL"]
region = os.environ["MCP_REGION"]
invoke_timeout = float(os.environ["MCP_TIMEOUT"])
session = boto3.Session(profile_name=os.environ["MCP_PROFILE"])
creds = session.get_credentials().get_frozen_credentials()


def call(payload, read_timeout):
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}
    req = AWSRequest(method="POST", url=url, data=data, headers=headers)
    SigV4Auth(creds, "bedrock-agentcore", region).add_auth(req)
    r = urllib.request.Request(url, data=data, headers=dict(req.headers), method="POST")
    with urllib.request.urlopen(r, timeout=read_timeout) as resp:
        body = resp.read().decode()
    # Responses may be SSE-framed ("event: message\ndata: {...}")
    if "data:" in body and not body.lstrip().startswith("{"):
        body = next(l[5:].strip() for l in body.splitlines() if l.startswith("data:"))
    return json.loads(body)


def fail(message):
    sys.stderr.write(message.rstrip() + "\n")
    sys.exit(1)


try:
    call({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"protocolVersion": "2025-03-26", "capabilities": {},
                     "clientInfo": {"name": "smoke-test", "version": "0"}}}, 60)

    listed = call({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, 60)
    tools = (listed.get("result") or {}).get("tools") or []
    spec = next((t for t in tools if t.get("name") == "investigate"), None)
    if spec is None:
        fail("the runtime does not expose an 'investigate' tool; found: "
             + ", ".join(sorted(t.get("name", "?") for t in tools)))

    schema = spec.get("inputSchema") or {}
    required = schema.get("required") or []
    argument = required[0] if required else next(iter(schema.get("properties") or {}), "")
    if not argument:
        fail("the 'investigate' tool declares no input argument")

    answered = call({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                     "params": {"name": "investigate",
                                "arguments": {argument: os.environ["MCP_SYMPTOM"]}}},
                    invoke_timeout)
    if answered.get("error"):
        fail("investigate returned a JSON-RPC error: "
             + json.dumps(answered["error"])[:300])

    result = answered.get("result") or {}
    if result.get("isError"):
        fail("investigate reported a tool error: " + json.dumps(result)[:300])

    payload = result.get("structuredContent")
    if payload is None:
        text = next((b.get("text") for b in (result.get("content") or [])
                     if b.get("type") == "text"), None)
        if text is None:
            fail("investigate returned no structured content and no text block")
        payload = json.loads(text)
    # FastMCP wraps a non-dict return under "result"; the tool returns a dict,
    # so unwrap only when the expected shape is absent.
    if isinstance(payload, dict) and "status" not in payload \
            and isinstance(payload.get("result"), dict):
        payload = payload["result"]

    print(json.dumps({"argument": argument, "payload": payload}))
except urllib.error.HTTPError as e:
    fail(f"HTTP {e.code}: {e.read().decode()[:300]}")
except Exception as e:  # noqa: BLE001 — the caller only needs the reason
    fail(f"{type(e).__name__}: {e}")
PYEOF
}

# Validate the returned report against the schema the reports contract defines.
# Reads the report JSON from a file so the jq checks stay readable.
validate_report_schema() {
  local report_file="$1"
  local valid=true
  local field_name sub_field

  for field_name in business_impact root_cause evidence_timeline telemetry; do
    if ! jq -e "has(\"${field_name}\")" "$report_file" &>/dev/null; then
      echo "    MISSING: ${field_name}"
      valid=false
    else
      echo "    OK: ${field_name}"
    fi
  done

  for sub_field in fault_id confidence; do
    if ! jq -e ".root_cause | has(\"${sub_field}\")" "$report_file" &>/dev/null; then
      echo "    MISSING: root_cause.${sub_field}"
      valid=false
    else
      echo "    OK: root_cause.${sub_field}"
    fi
  done

  for sub_field in round_trips tokens duration_seconds tool_calls; do
    if ! jq -e ".telemetry | has(\"${sub_field}\")" "$report_file" &>/dev/null; then
      echo "    MISSING: telemetry.${sub_field}"
      valid=false
    fi
  done

  [[ "$valid" == "true" ]]
}

print_report_summary() {
  local report_file="$1"
  echo "  ─── Report Summary ───────────────────────────────────────────"
  echo "  Report ID:       $(jq -r '.report_id // "n/a"' "$report_file")"
  echo "  Status:          $(jq -r '.status // "n/a"' "$report_file")"
  echo "  Created:         $(jq -r '.created_at // "n/a"' "$report_file")"
  echo "  Business Impact: $(jq -r '.business_impact // "n/a"' "$report_file" | head -c 120)"
  echo "  Root Cause:      $(jq -r '.root_cause.fault_id // "n/a"' "$report_file") (confidence: $(jq -r '.root_cause.confidence // "n/a"' "$report_file"))"
  echo "  Evidence Items:  $(jq '.evidence_timeline | length' "$report_file" 2>/dev/null || echo 0)"
  echo "  Telemetry:"
  echo "    Duration:      $(jq -r '.telemetry.duration_seconds // "n/a"' "$report_file")s"
  echo "    Tool Calls:    $(jq -r '.telemetry.tool_calls // "n/a"' "$report_file")"
  echo "    Tokens:        $(jq -r '.telemetry.tokens // "n/a"' "$report_file")"
  echo "  ─────────────────────────────────────────────────────────────"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Confirm the report just returned reached S3
#
# `archive_to_s3()` keys the object as reports/<YYYY-MM-DD>/<report_id>.json,
# so the key is derived from the returned report rather than guessed from a
# timestamp window. The date is taken at archive time, which is up to a
# ten-minute investigation after created_at, so both candidate dates are tried.
# ═══════════════════════════════════════════════════════════════════════════════
confirm_report_archived() {
  local bucket="$1"
  local report_id="$2"
  local created_at="$3"

  local created_date="${created_at%%T*}"
  local today
  today=$(date -u +"%Y-%m-%d")

  local candidates="$created_date"
  if [[ "$today" != "$created_date" ]]; then
    candidates="${candidates} ${today}"
  fi

  # Two attempts: the put completes before the MCP response returns, so this is
  # a read of an already-written object, not a race — the retry only absorbs a
  # transient error on the HeadObject itself.
  local attempt date_prefix key
  for attempt in 1 2; do
    for date_prefix in $candidates; do
      key="reports/${date_prefix}/${report_id}.json"
      if aws_cmd s3api head-object --bucket "$bucket" --key "$key" &>/dev/null; then
        echo "$key"
        return 0
      fi
    done
    [[ "$attempt" == "1" ]] && sleep 5
  done

  return 1
}

# Invoke one fallback agent and validate what it returns, then confirm the
# archive. Returns 0 only if the report is schema-valid; sets ARCHIVE_OK.
check_fallback_agent() {
  local ssm_name="$1"
  local bucket="$2"
  local timeout="$3"

  ARCHIVE_OK=false

  local runtime_arn
  runtime_arn=$(runtime_arn_for "$ssm_name")
  if [[ -z "$runtime_arn" || "$runtime_arn" == "None" ]]; then
    echo "  ERROR: /aiops-poc/agents/${ssm_name}/runtime-arn not found in SSM." >&2
    echo "         Deploy the agents/infra stack first." >&2
    return 1
  fi

  local endpoint
  endpoint=$(mcp_url "$runtime_arn")
  echo "  Runtime ARN:  ${runtime_arn}"
  echo "  MCP endpoint: ${endpoint}"
  echo "  Invoking 'investigate' (up to ${timeout}s — the agent's own hard"
  echo "  timeout is 10 minutes, so this is one model call, not a poll)..."

  local answered
  if ! answered=$(mcp_investigate "$endpoint" "$SMOKE_SYMPTOM" "$timeout"); then
    echo "  FAIL: the 'investigate' call did not return a report (see the error above)."
    return 1
  fi

  local argument status
  argument=$(echo "$answered" | jq -r '.argument')
  status=$(echo "$answered" | jq -r '.payload.status // "unknown"')
  echo "  Answered via argument '${argument}', status: ${status}"

  local tmpfile
  tmpfile=$(mktemp)
  echo "$answered" | jq '.payload.report' > "$tmpfile"

  if [[ "$(jq -r 'type' "$tmpfile")" != "object" ]]; then
    echo "  FAIL: the response carried no 'report' object."
    rm -f "$tmpfile"
    return 1
  fi

  echo "  Validating report schema..."
  local schema_ok=true
  validate_report_schema "$tmpfile" || schema_ok=false

  echo ""
  print_report_summary "$tmpfile"

  local report_id created_at
  report_id=$(jq -r '.report_id // empty' "$tmpfile")
  created_at=$(jq -r '.created_at // empty' "$tmpfile")
  rm -f "$tmpfile"

  # The archive is now a side effect of an invocation this script caused, so a
  # missing object is a real defect rather than an unexercised path.
  echo ""
  if [[ -z "$report_id" ]]; then
    echo "  Archive: SKIPPED — the report carries no report_id to key on"
  else
    local key
    if key=$(confirm_report_archived "$bucket" "$report_id" "$created_at"); then
      echo "  Archive: OK — s3://${bucket}/${key}"
      ARCHIVE_OK=true
    else
      echo "  Archive: MISSING — no object at reports/<date>/${report_id}.json in"
      echo "           s3://${bucket}. The agent returned a report but did not"
      echo "           archive it. Check the runtime log for the archive failure"
      echo "           (a denied s3:PutObject is logged there), and that the"
      echo "           image is current — archival is unconditional in both agents."
    fi
  fi

  [[ "$schema_ok" == "true" ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main execution
# ═══════════════════════════════════════════════════════════════════════════════
main() {
  echo "╔═══════════════════════════════════════════════════════════════════╗"
  echo "║  AI-Ops PoC — Smoke Test                                         ║"
  echo "╚═══════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Profile: ${PROFILE}"
  echo "  Region:  ${REGION}"
  echo ""

  local fn_name
  fn_name=$(resolve_function_name)
  local report_bucket
  report_bucket=$(resolve_report_bucket)

  local managed_pass=true
  local custom_pass=true
  local archive_pass=true
  local overall_pass=true

  # ─── Step 1: Fire test webhook ─────────────────────────────────────────────
  # Only the managed estate needs it — the custom estate check invokes the
  # fallback agents itself, so --custom-only no longer opens an investigation
  # (and no longer spends an agent run) it does not assert on.
  if [[ "$CUSTOM_ONLY" != "true" ]]; then
    echo "┌───────────────────────────────────────────────────────────────────┐"
    echo "│ Step 1: Fire test webhook via Lambda (${fn_name})                 │"
    echo "└───────────────────────────────────────────────────────────────────┘"
    echo ""

    if ! fire_test_webhook "$fn_name"; then
      echo ""
      echo "  FAIL: Could not invoke the webhook bridge Lambda"
      managed_pass=false
    else
      echo ""
      echo "  OK: Test webhook fired"
    fi

    # ─── Step 2: Confirm managed investigation ──────────────────────────────
    if [[ "$managed_pass" == "true" ]]; then
      echo ""
      echo "┌───────────────────────────────────────────────────────────────────┐"
      echo "│ Step 2: Confirm first-responder investigation (managed estate)    │"
      echo "└───────────────────────────────────────────────────────────────────┘"
      echo ""

      if ! confirm_managed_investigation "$MANAGED_TIMEOUT"; then
        managed_pass=false
      else
        echo ""
        echo "  OK: Managed estate investigation confirmed"
      fi
    fi

    [[ "$managed_pass" == "true" ]] || overall_pass=false
  fi

  # ─── Step 3: Invoke the fallback agents (custom estate) ───────────────────
  if [[ "$MANAGED_ONLY" != "true" ]]; then
    echo ""
    echo "┌───────────────────────────────────────────────────────────────────┐"
    echo "│ Step 3: Invoke fallback 'investigate' over SigV4 (custom estate)  │"
    echo "└───────────────────────────────────────────────────────────────────┘"
    echo ""

    local peer
    peer=$(resolve_peer)
    local agent_list
    if ! agent_list=$(agents_for_peer "$peer"); then
      echo "  ERROR: invalid peer value '${peer}'. Must be devops, kb or both." >&2
      exit 1
    fi

    echo "  Peer:   ${peer}"
    echo "  Agents: ${agent_list}"
    echo "  Bucket: ${report_bucket}"

    local agent
    for agent in $agent_list; do
      echo ""
      echo "  ── ${agent} ──────────────────────────────────────────────"
      if ! check_fallback_agent "$agent" "$report_bucket" "$CUSTOM_TIMEOUT"; then
        custom_pass=false
      fi
      if [[ "$ARCHIVE_OK" != "true" ]]; then
        archive_pass=false
      fi
    done

    if [[ "$custom_pass" == "true" ]]; then
      echo ""
      echo "  OK: every selected fallback agent returned a schema-valid report"
    fi
    [[ "$custom_pass" == "true" ]] || overall_pass=false
    [[ "$archive_pass" == "true" ]] || overall_pass=false
  fi

  # ─── Results ───────────────────────────────────────────────────────────────
  echo ""
  echo "╔═══════════════════════════════════════════════════════════════════╗"
  echo "║  Smoke Test Results                                              ║"
  echo "╠═══════════════════════════════════════════════════════════════════╣"

  if [[ "$CUSTOM_ONLY" != "true" ]]; then
    if [[ "$managed_pass" == "true" ]]; then
      echo "║  Managed estate (webhook → investigation):  PASS               ║"
    else
      echo "║  Managed estate (webhook → investigation):  FAIL               ║"
    fi
  fi

  if [[ "$MANAGED_ONLY" != "true" ]]; then
    if [[ "$custom_pass" == "true" ]]; then
      echo "║  Custom estate  (investigate → report):     PASS               ║"
    else
      echo "║  Custom estate  (investigate → report):     FAIL               ║"
    fi
    if [[ "$archive_pass" == "true" ]]; then
      echo "║  Report archival (S3, by report_id):        PASS               ║"
    else
      echo "║  Report archival (S3, by report_id):        FAIL               ║"
    fi
  fi

  echo "╠═══════════════════════════════════════════════════════════════════╣"
  if [[ "$overall_pass" == "true" ]]; then
    echo "║  Overall:                                    PASS               ║"
  else
    echo "║  Overall:                                    FAIL               ║"
  fi
  echo "╚═══════════════════════════════════════════════════════════════════╝"
  echo ""

  if [[ "$overall_pass" == "true" ]]; then
    exit 0
  else
    exit 1
  fi
}

main
