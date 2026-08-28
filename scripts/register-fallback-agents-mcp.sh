#!/usr/bin/env bash
# register-fallback-agents-mcp.sh — Register the self-managed fallback agents
# (backend_devops_agent, backend_kb_agent — dual-protocol Strands agents on
# Bedrock AgentCore Runtime, serving MCP) as MCP capability providers in the
# APP-TEAM Agent Space.
#
# ════════════════════════════════════════════════════════════════════════
#  PRIMARY fallback registration (MCP variant).
#
#  The A2A variant — scripts/register-fallback-agents.sh (remoteagentsigv4)
#  — is kept intact as the ALTERNATE. MCP was promoted (2026-07) for the
#  same reason as the space-to-space link: the MCP third-party gate has a
#  known unblock process ("third-party MCP access", security review in
#  docs/security/mcp-security-review.md), while the remote-agent
#  allowlist gate has no findable exemption process.
# ════════════════════════════════════════════════════════════════════════
#
# Mechanism (mirrors register-diagnostics-mcp.sh, verified live there):
#   • MCP endpoint (SigV4, service "bedrock-agentcore"):
#       POST https://bedrock-agentcore.{region}.amazonaws.com/
#            runtimes/{urlencoded-runtime-arn}/invocations?qualifier=DEFAULT
#     (stateless streamable HTTP; JSON-RPC passthrough to the container's
#     /mcp path.)
#   • Registration: register-service --service mcpserversigv4, serviceDetails
#       {"mcpserversigv4": {name, endpoint, description,
#        authorizationConfig: {region, service: "bedrock-agentcore",
#        roleArn: <trust role>}}}
#   • Association config REQUIRES an explicit tool list — each fallback
#     agent exposes exactly one tool: `investigate`.
#
# Each endpoint is verified live (SigV4 initialize + tools/list) before
# registration. If a runtime is still serving A2A (agents/infra not yet
# redeployed with protocolConfiguration MCP + SERVE_PROTOCOL=MCP), the
# script says so explicitly and skips that agent rather than registering a
# dead endpoint.
#
# ACCOUNT GATES (as of 2026-07). Two distinct gates can fire here:
#   1. The general capability-registration allowlist gate
#      (AccessDeniedException: "Account ... is not authorized. Only external
#      accounts and exempted accounts are allowed at this time.").
#   2. The MCP-specific third-party gate (ValidationException: "This account
#      can only register internally allowlisted MCP servers. To register
#      other MCP servers, enable third-party access on your account.") —
#      a console-side account setting, not exposed in the CLI/API.
# Endpoint verification still runs either way; if a gate fires, the script
# prints the applicable guidance + pre-filled manual console steps and
# exits 2. Re-run once unblocked; the script is idempotent throughout.
#
# Honors /aiops-poc/peer (devops | kb | both) like register-fallback-agents.sh.
#
# Usage:
#   scripts/register-fallback-agents-mcp.sh [--profile PROFILE] [--region REGION] [--peer devops|kb|both]
#
# Defaults:
#   --profile  config/accounts.json → ops.profile  (resolved by scripts/lib/config.sh)
#   --region   config/accounts.json → ops.region   (resolved by scripts/lib/config.sh)
#   --peer     value of /aiops-poc/peer in SSM (fallback: both)

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
PROFILE_FLAG=""
REGION_FLAG=""
PEER_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE_FLAG="$2"; shift 2 ;;
    --region)  REGION_FLAG="$2"; shift 2 ;;
    --peer)    PEER_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--profile PROFILE] [--region REGION] [--peer devops|kb|both]"
      echo ""
      echo "Registers the AgentCore fallback agents as MCP capability providers"
      echo "(mcpserversigv4) in the app-team Agent Space. PRIMARY variant;"
      echo "the A2A alternate is register-fallback-agents.sh."
      echo ""
      echo "Options:"
      echo "  --profile  AWS CLI profile (default: config/accounts.json → ops.profile)"
      echo "  --region   AWS region (default: config/accounts.json → ops.region)"
      echo "  --peer     Override /aiops-poc/peer (devops | kb | both)"
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

for cmd in aws jq python3; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' is required." >&2; exit 1; }
done

aws_cmd() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

OPS_ACCOUNT_ID="$CONFIG_OPS_ACCOUNT"
REGISTRATION_ROLE_ARN="arn:aws:iam::${OPS_ACCOUNT_ID}:role/aiops-poc-remote-agent-registration"

# ─── Peer selection ─────────────────────────────────────────────────────────
if [[ -n "$PEER_OVERRIDE" ]]; then
  PEER="$PEER_OVERRIDE"
else
  PEER=$(aws_cmd ssm get-parameter --name "/aiops-poc/peer" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo "both")
fi
case "$PEER" in
  devops|kb|both) ;;
  *) echo "ERROR: Invalid peer value '${PEER}'. Must be devops|kb|both." >&2; exit 1 ;;
esac

# ─── Resolve app-team space + runtime ARNs from SSM ─────────────────────────
APP_TEAM_ARN=$(aws_cmd ssm get-parameter \
  --name "/aiops-poc/agent-spaces/app-team/arn" \
  --query 'Parameter.Value' --output text 2>/dev/null) || {
  echo "ERROR: Could not read /aiops-poc/agent-spaces/app-team/arn from SSM." >&2
  exit 1
}
APP_TEAM_SPACE_ID="${APP_TEAM_ARN##*/}"

get_runtime_arn() {
  aws_cmd ssm get-parameter --name "/aiops-poc/agents/$1/runtime-arn" \
    --query 'Parameter.Value' --output text 2>/dev/null || {
    echo "ERROR: Could not read /aiops-poc/agents/$1/runtime-arn from SSM." >&2
    echo "       Deploy the agents/infra stack first." >&2
    exit 1
  }
}

urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# AgentCore data-plane MCP invocation URL for a runtime (SigV4-signed POST;
# JSON-RPC passthrough to the container's /mcp path).
mcp_url() {
  echo "https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/$(urlencode "$1")/invocations?qualifier=DEFAULT"
}

# SigV4-signed MCP verification: initialize + tools/list over stateless
# streamable HTTP. Prints {"server": ..., "tools": [...]} on success.
verify_mcp() {
  URL="$1" PROFILE="$PROFILE" REGION="$REGION" python3 - <<'PYEOF'
import json, os, sys, urllib.request, urllib.error
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

url = os.environ["URL"]
session = boto3.Session(profile_name=os.environ["PROFILE"])
creds = session.get_credentials().get_frozen_credentials()

def call(payload):
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}
    req = AWSRequest(method="POST", url=url, data=data, headers=headers)
    SigV4Auth(creds, "bedrock-agentcore", os.environ["REGION"]).add_auth(req)
    r = urllib.request.Request(url, data=data, headers=dict(req.headers), method="POST")
    with urllib.request.urlopen(r, timeout=60) as resp:
        body = resp.read().decode()
    # Responses may be SSE-framed ("event: message\ndata: {...}")
    if "data:" in body and not body.lstrip().startswith("{"):
        body = next(l[5:].strip() for l in body.splitlines() if l.startswith("data:"))
    return json.loads(body)

try:
    init = call({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"protocolVersion": "2025-03-26", "capabilities": {},
                            "clientInfo": {"name": "register-fallback-agents-mcp", "version": "0"}}})
    server = init.get("result", {}).get("serverInfo", {}).get("name", "?")
    tools = call({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    names = [t["name"] for t in tools["result"]["tools"]]
    print(json.dumps({"server": server, "tools": names}))
except urllib.error.HTTPError as e:
    sys.stderr.write(f"HTTP {e.code}: {e.read().decode()[:300]}\n")
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f"{type(e).__name__}: {e}\n")
    sys.exit(1)
PYEOF
}

# SigV4-signed GET of the A2A agent card — used only to diagnose "runtime
# still serving A2A" when MCP verification fails.
a2a_card_probe() {
  URL="https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/$(urlencode "$1")/invocations/.well-known/agent-card.json" \
  PROFILE="$PROFILE" REGION="$REGION" python3 - <<'PYEOF'
import json, os, sys, urllib.request, urllib.error
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

url = os.environ["URL"]
session = boto3.Session(profile_name=os.environ["PROFILE"])
creds = session.get_credentials().get_frozen_credentials()
req = AWSRequest(method="GET", url=url, headers={"Accept": "application/json"})
SigV4Auth(creds, "bedrock-agentcore", os.environ["REGION"]).add_auth(req)
r = urllib.request.Request(url, headers=dict(req.headers), method="GET")
try:
    with urllib.request.urlopen(r, timeout=30) as resp:
        card = json.loads(resp.read().decode())
    print(card.get("name", "?"))
except Exception:
    sys.exit(1)
PYEOF
}

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  DevOps Agent — fallback agents (MCP) → app-team space           ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Profile:        ${PROFILE}"
echo "  Region:         ${REGION}"
echo "  Peer:           ${PEER}"
echo "  App-team space: ${APP_TEAM_SPACE_ID}"
echo "  Trust role:     ${REGISTRATION_ROLE_ARN}"
echo ""

GATE_BLOCKED=false
STILL_A2A=false
MANUAL_STEPS=""

# register_agent_mcp <ssm-name> <service-name> <description>
register_agent_mcp() {
  local ssm_name="$1" service_name="$2" description="$3"

  local runtime_arn endpoint
  runtime_arn=$(get_runtime_arn "$ssm_name")
  endpoint=$(mcp_url "$runtime_arn")

  echo "── ${service_name} ──────────────────────────────────────────────────"
  echo "  Runtime ARN:  ${runtime_arn}"
  echo "  MCP endpoint: ${endpoint}"

  # Step 1: verify the MCP endpoint (read-only, SigV4: initialize + tools/list)
  local tools_json tool_names tool_count
  if tools_json=$(verify_mcp "$endpoint"); then
    tool_names=$(echo "$tools_json" | jq -c '.tools')
    tool_count=$(echo "$tool_names" | jq 'length')
    echo "  ✓ MCP server '$(echo "$tools_json" | jq -r '.server')' answered with ${tool_count} tool(s):"
    echo "$tool_names" | jq -r '.[] | "      • " + .'
    if ! echo "$tool_names" | jq -e 'index("investigate")' >/dev/null; then
      echo "ERROR: '${service_name}' does not expose the 'investigate' tool — unexpected image?" >&2
      exit 1
    fi
  else
    # MCP failed — check whether the runtime is still serving A2A.
    local card_name
    if card_name=$(a2a_card_probe "$runtime_arn"); then
      echo "  ⚠ SKIPPED: MCP verification failed, but the A2A agent card answered"
      echo "    (name: ${card_name}) — this runtime is still serving A2A."
      echo "    Redeploy agents/infra (protocolConfiguration MCP +"
      echo "    SERVE_PROTOCOL=MCP) and re-run this script."
      STILL_A2A=true
      echo ""
      return 0
    fi
    echo "ERROR: MCP endpoint verification failed for ${service_name}" >&2
    echo "       (and the A2A card probe failed too — runtime unhealthy?)." >&2
    exit 1
  fi

  # Step 2: register the service (idempotent by name; account-gated)
  local service_id
  service_id=$(aws_cmd devops-agent list-services \
    --filter-service-type mcpserversigv4 \
    --query "services[?name=='${service_name}'].serviceId | [0]" \
    --output text 2>/dev/null || echo "None")

  if [[ -n "$service_id" && "$service_id" != "None" ]]; then
    echo "  ✓ Reusing existing service: ${service_id}"
  else
    local service_details register_out register_rc
    service_details=$(jq -n \
      --arg name "$service_name" \
      --arg endpoint "$endpoint" \
      --arg description "$description" \
      --arg region "$REGION" \
      --arg role_arn "$REGISTRATION_ROLE_ARN" \
      '{mcpserversigv4: {name: $name, endpoint: $endpoint, description: $description,
        authorizationConfig: {region: $region, service: "bedrock-agentcore", roleArn: $role_arn}}}')

    set +e
    register_out=$(aws_cmd devops-agent register-service \
      --service mcpserversigv4 \
      --name "$service_name" \
      --service-details "$service_details" \
      --output json 2>&1)
    register_rc=$?
    set -e

    if [[ $register_rc -ne 0 ]]; then
      local gate_msg=""
      if echo "$register_out" | grep -q "not authorized. Only external accounts"; then
        gate_msg="the account allowlist gate — re-run once the account exemption lands."
      elif echo "$register_out" | grep -q "enable third-party access"; then
        gate_msg="the MCP third-party gate — only internally allowlisted MCP servers
    can be registered until 'third-party access' is enabled on the account
    (console-side setting; see docs/security/mcp-security-review.md).
    Re-run once enabled."
      fi
      if [[ -n "$gate_msg" ]]; then
        echo "  ✗ BLOCKED: $(echo "$register_out" | grep -oE '(AccessDeniedException|ValidationException).*' || echo "$register_out")"
        echo "    This is ${gate_msg}"
        GATE_BLOCKED=true
        MANUAL_STEPS+="
  ┌─────────────────────────────────────────────────────────────────────┐
  │ Manual Registration: ${service_name}
  ├─────────────────────────────────────────────────────────────────────┤
  │ A. Capability Providers → MCP Server → Register                     │
  │    Name:           ${service_name}
  │    Endpoint:       ${endpoint}
  │    Description:    ${description:0:60}...
  │    Authentication: AWS SigV4                                        │
  │    SigV4 region:   ${REGION}
  │    SigV4 service:  bedrock-agentcore                                │
  │    Role ARN:       ${REGISTRATION_ROLE_ARN}
  │ B. Agent Space '${APP_TEAM_SPACE_ID}'
  │    → Capabilities tab → MCP Servers → Add                           │
  │    → select '${service_name}', enable the 'investigate' tool → Add  │
  └─────────────────────────────────────────────────────────────────────┘"
        echo ""
        return 0
      fi
      echo "ERROR: register-service failed for ${service_name}:" >&2
      echo "$register_out" >&2
      exit 1
    fi
    service_id=$(echo "$register_out" | jq -r '.serviceId')
    echo "  ✓ Registered new service: ${service_id}"
  fi

  # Step 3: associate to the app-team space (idempotent). The mcpserversigv4
  # association config requires an explicit tool allowlist — just `investigate`.
  local assoc_id
  assoc_id=$(aws_cmd devops-agent list-associations \
    --agent-space-id "$APP_TEAM_SPACE_ID" \
    --query "associations[?serviceId=='${service_id}'].associationId | [0]" \
    --output text 2>/dev/null || echo "None")

  if [[ -n "$assoc_id" && "$assoc_id" != "None" ]]; then
    echo "  ✓ Association already exists: ${assoc_id}"
  else
    local assoc_out
    assoc_out=$(aws_cmd devops-agent associate-service \
      --agent-space-id "$APP_TEAM_SPACE_ID" \
      --service-id "$service_id" \
      --configuration '{"mcpserversigv4": {"tools": ["investigate"]}}' \
      --output json)
    assoc_id=$(echo "$assoc_out" | jq -r '.association.associationId')
    echo "  ✓ Association created: ${assoc_id} (status: $(echo "$assoc_out" | jq -r '.association.status // "unknown"'), tools: investigate)"
  fi
  echo ""
}

# Descriptions reflect the knowledge-only descope (2026-07): the fallback
# agents are runbook/KB knowledge checkers with NO live telemetry — the
# live-telemetry layer is the platform-space investigator
# (aiops-poc-platform-space-mcp). These are explicitly demoted to SECONDARY
# "use after the platform-space live investigator" fallbacks so the
# responder reaches for live state first.
# NOTE: RegisterService caps mcpserversigv4 descriptions at 500 chars, so the
# devops-agent copy below is the ≤500-char form of the intended wording.
if [[ "$PEER" == "devops" || "$PEER" == "both" ]]; then
  register_agent_mcp "backend-devops-agent" "aiops-poc-backend-devops-agent-mcp" \
    "SECONDARY knowledge-only fallback — use ONLY after the platform-space live investigator (aiops-poc-platform-space-mcp), or when live investigation is unavailable/inconclusive. Single 'investigate' tool: consults documented PetAdoptions backend runbooks/playbooks and returns likely root causes, the verification steps the owning team should run, and remediation guidance. NO live telemetry — it CANNOT confirm any service's current state; findings are documented knowledge, not observed fact."
fi

if [[ "$PEER" == "kb" || "$PEER" == "both" ]]; then
  register_agent_mcp "backend-kb-agent" "aiops-poc-backend-kb-agent-mcp" \
    "SECONDARY knowledge-only fallback — use ONLY after the platform-space live investigator (aiops-poc-platform-space-mcp), or when live investigation is unavailable or inconclusive. Single 'investigate' tool: checks the PetAdoptions architecture knowledge base for a symptom, returns documented likely root causes WITH citations plus the checks the owning team should run, and escalates a summary to the owning team via SNS email. NO live telemetry — it CANNOT confirm current live state."
fi

if [[ "$STILL_A2A" == "true" ]]; then
  cat <<EOF
═══════════════════════════════════════════════════════════════════════
⚠ One or more runtimes are still serving A2A — they were skipped.

Redeploy the agent runtimes with the MCP protocol first:

  cd agents/infra && npx cdk deploy --profile ${PROFILE}

then re-run:

  scripts/register-fallback-agents-mcp.sh --peer ${PEER}
═══════════════════════════════════════════════════════════════════════
EOF
  exit 2
fi

if [[ "$GATE_BLOCKED" == "true" ]]; then
  cat <<EOF
═══════════════════════════════════════════════════════════════════════
✗ Registration is blocked by an account gate.

Endpoint verification succeeded — the URL convention and SigV4 auth are
confirmed working. Once unblocked, re-run:

  scripts/register-fallback-agents-mcp.sh --peer ${PEER}

Or register manually in the DevOps Agent console (${REGION}):
${MANUAL_STEPS}

(Note: the console calls the same API, so the account gate may block the
console flow too — in that case the account exemption is required.)
═══════════════════════════════════════════════════════════════════════
EOF
  exit 2
fi

echo "═══════════════════════════════════════════════════════════════════"
echo "✓ Fallback agents registered as MCP capability providers in app-team."
echo "  Each exposes a single 'investigate' tool."
echo "  Verify: scripts/test-fallback.sh --profile ${PROFILE}"
echo "═══════════════════════════════════════════════════════════════════"
