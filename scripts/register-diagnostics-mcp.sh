#!/usr/bin/env bash
# register-diagnostics-mcp.sh — Register the diagnostics MCP server
# (diagnostics_mcp on Bedrock AgentCore Runtime) as an MCP capability
# provider in the PLATFORM Agent Space.
#
# ════════════════════════════════════════════════════════════════════════
#  OPTIONAL / DESCOPED FROM THE DEMO (user decision 2026-07).
#
#  The diagnostics MCP has no demo value: its platform-space association
#  was removed from the demo path (the Platform DevOps Agent's native
#  account association covers live telemetry). The runtime stays deployed
#  and the SERVICE stays registered — re-running this script recreates the
#  association, making the descope fully reversible.
#
#  Future-design note: the current tool inventory bakes resource names
#  into the server config; the right design is caller-passed resource
#  names (service/table/canary as tool arguments validated against an
#  allowlist) rather than baked-in inventory.
# ════════════════════════════════════════════════════════════════════════
#
# AUTH ANALYSIS (2026-07). The diagnostics MCP runtime is SigV4-only:
#   • The FastMCP container (mcp-servers/backend-diagnostics) has no auth
#     layer of its own — inbound auth is entirely AgentCore Runtime's, and
#     the CDK CfnRuntime has no authorizerConfiguration (no OAuth/JWT), so
#     the data plane accepts SigV4 (service "bedrock-agentcore") only.
#   • The plain `mcpserver` registration type offers bearer/apiKey/OAuth —
#     none of which the runtime accepts, so that type is NOT viable without
#     agent/infra changes.
#   • RESOLUTION: the service model has a dedicated `mcpserversigv4` type
#     (verified in the 2026-01-01 model) whose authorizationConfig is
#     {region, service, roleArn, mcpRoleArn?, customHeaders?} — exactly the
#     SigV4 shape AgentCore needs. No mismatch remains; no code changes
#     required.
#
# Mechanism (verified against the live service model + endpoint):
#   • MCP endpoint (SigV4, service "bedrock-agentcore"; verified live with
#     initialize + tools/list → 7 tools):
#       POST https://bedrock-agentcore.{region}.amazonaws.com/
#            runtimes/{urlencoded-runtime-arn}/invocations?qualifier=DEFAULT
#     (stateless streamable HTTP; JSON-RPC passthrough to the container's
#     /mcp path.)
#   • Registration: register-service --service mcpserversigv4, serviceDetails
#       {"mcpserversigv4": {name, endpoint, description,
#        authorizationConfig: {region, service: "bedrock-agentcore",
#        roleArn: <trust role>}}}
#   • Association config REQUIRES an explicit tool list:
#       {"mcpserversigv4": {"tools": [...]}}
#     The tool list is taken from the live tools/list during verification.
#
# ACCOUNT GATES (as of 2026-07). Two distinct gates can fire here:
#   1. The general capability-registration allowlist gate
#      (AccessDeniedException: "Account ... is not authorized. Only external
#      accounts and exempted accounts are allowed at this time.") — needs
#      the account exemption the team is already pursuing.
#   2. An MCP-specific third-party gate (ValidationException: "This account
#      can only register internally allowlisted MCP servers. To register
#      other MCP servers, enable third-party access on your account.") —
#      observed live on this account. "Third-party access" is an account
#      setting; it is NOT exposed in the devops-agent CLI model (no
#      operation mentions it) nor at any obvious cp.aidevops path, so it
#      appears to be a console-side settings toggle. Enable it in the
#      DevOps Agent console settings (or ask AWS to), then re-run.
# Endpoint verification still runs either way; if a gate fires, the script
# prints the applicable guidance + pre-filled manual console steps and
# exits 2. Re-run once unblocked; the script is idempotent throughout.
#
# Usage:
#   scripts/register-diagnostics-mcp.sh [--profile PROFILE] [--region REGION]
#
# Defaults:
#   --profile  config/accounts.json → ops.profile  (resolved by scripts/lib/config.sh)
#   --region   config/accounts.json → ops.region   (resolved by scripts/lib/config.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# The OPS profile and region come from the Config_Resolver — the one shared
# location that reads config/accounts.json (Requirement 2.6). The flags are
# handed to it so precedence stays flag > env > file > template default
# (Requirement 2.1); the literal defaults this script used to carry are the
# template's declared defaults.
source "${PROJECT_ROOT}/scripts/lib/config.sh"

SERVICE_NAME="aiops-poc-diagnostics-mcp"
DESCRIPTION="Deterministic backend diagnostics tools (read-only, no LLM): ECS service health, Lambda stats, SQS queue stats, DynamoDB health, Aurora/RDS health, Synthetics canary results, recent CloudWatch alarms for the PetAdoptions backend."

# ─── Defaults (flags override the resolved values) ─────────────────────────
PROFILE_FLAG=""
REGION_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE_FLAG="$2"; shift 2 ;;
    --region)  REGION_FLAG="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--profile PROFILE] [--region REGION]"
      echo ""
      echo "Registers the diagnostics_mcp AgentCore runtime as an MCP capability"
      echo "provider (mcpserversigv4) in the platform Agent Space."
      echo ""
      echo "Options:"
      echo "  --profile  AWS CLI profile (default: config/accounts.json → ops.profile)"
      echo "  --region   AWS region (default: config/accounts.json → ops.region)"
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

# ─── Resolve platform space + runtime ARN from SSM ──────────────────────────
PLATFORM_ARN=$(aws_cmd ssm get-parameter \
  --name "/aiops-poc/agent-spaces/platform/arn" \
  --query 'Parameter.Value' --output text 2>/dev/null) || {
  echo "ERROR: Could not read /aiops-poc/agent-spaces/platform/arn from SSM." >&2
  exit 1
}
PLATFORM_SPACE_ID="${PLATFORM_ARN##*/}"

RUNTIME_ARN=$(aws_cmd ssm get-parameter \
  --name "/aiops-poc/agents/diagnostics-mcp/runtime-arn" \
  --query 'Parameter.Value' --output text 2>/dev/null) || {
  echo "ERROR: Could not read /aiops-poc/agents/diagnostics-mcp/runtime-arn from SSM." >&2
  echo "       Deploy the agents/infra stack first." >&2
  exit 1
}

ENCODED_ARN=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$RUNTIME_ARN")
MCP_ENDPOINT="https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/${ENCODED_ARN}/invocations?qualifier=DEFAULT"

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  DevOps Agent — diagnostics MCP → platform space                 ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Profile:        ${PROFILE}"
echo "  Region:         ${REGION}"
echo "  Platform space: ${PLATFORM_SPACE_ID}"
echo "  Runtime ARN:    ${RUNTIME_ARN}"
echo "  MCP endpoint:   ${MCP_ENDPOINT}"
echo "  Trust role:     ${REGISTRATION_ROLE_ARN}"
echo ""

# ─── Step 1: Verify the MCP endpoint (read-only, SigV4) ─────────────────────
# initialize + tools/list over stateless streamable HTTP; captures the live
# tool list, which the association configuration requires.
echo "Step 1: Verify the MCP endpoint with SigV4 (initialize + tools/list)..."

TOOLS_JSON=$(URL="$MCP_ENDPOINT" PROFILE="$PROFILE" REGION="$REGION" python3 - <<'PYEOF'
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
                            "clientInfo": {"name": "register-diagnostics-mcp", "version": "0"}}})
    server = init.get("result", {}).get("serverInfo", {}).get("name", "?")
    tools = call({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    names = [t["name"] for t in tools["result"]["tools"]]
    print(json.dumps({"server": server, "tools": names}))
except urllib.error.HTTPError as e:
    sys.stderr.write(f"HTTP {e.code}: {e.read().decode()[:300]}\n")
    sys.exit(1)
PYEOF
) || { echo "ERROR: MCP endpoint verification failed." >&2; exit 1; }

TOOL_NAMES=$(echo "$TOOLS_JSON" | jq -c '.tools')
TOOL_COUNT=$(echo "$TOOL_NAMES" | jq 'length')
echo "  ✓ MCP server '$(echo "$TOOLS_JSON" | jq -r '.server')' answered with ${TOOL_COUNT} tools:"
echo "$TOOL_NAMES" | jq -r '.[] | "      • " + .'

# ─── Step 2: Register the service (idempotent; account-gated) ───────────────
echo ""
echo "Step 2: Register '${SERVICE_NAME}' (service type: mcpserversigv4)..."

SERVICE_ID=$(aws_cmd devops-agent list-services \
  --filter-service-type mcpserversigv4 \
  --query "services[?name=='${SERVICE_NAME}'].serviceId | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ -n "$SERVICE_ID" && "$SERVICE_ID" != "None" ]]; then
  echo "  ✓ Reusing existing service: ${SERVICE_ID}"
else
  SERVICE_DETAILS=$(jq -n \
    --arg name "$SERVICE_NAME" \
    --arg endpoint "$MCP_ENDPOINT" \
    --arg description "$DESCRIPTION" \
    --arg region "$REGION" \
    --arg role_arn "$REGISTRATION_ROLE_ARN" \
    '{mcpserversigv4: {name: $name, endpoint: $endpoint, description: $description,
      authorizationConfig: {region: $region, service: "bedrock-agentcore", roleArn: $role_arn}}}')

  set +e
  REGISTER_OUT=$(aws_cmd devops-agent register-service \
    --service mcpserversigv4 \
    --name "$SERVICE_NAME" \
    --service-details "$SERVICE_DETAILS" \
    --output json 2>&1)
  REGISTER_RC=$?
  set -e

  if [[ $REGISTER_RC -ne 0 ]]; then
    GATE_MSG=""
    if echo "$REGISTER_OUT" | grep -q "not authorized. Only external accounts"; then
      GATE_MSG="the account allowlist gate — re-run once the account exemption lands."
    elif echo "$REGISTER_OUT" | grep -q "enable third-party access"; then
      GATE_MSG="the MCP third-party gate — only internally allowlisted MCP servers
    can be registered until 'third-party access' is enabled on the account.
    This toggle is not in the CLI/API (verified against the service model);
    look for it in the DevOps Agent console account settings, or include it
    in the exemption request. Re-run once enabled."
    fi
    if [[ -n "$GATE_MSG" ]]; then
      cat <<EOF

  ✗ BLOCKED: $(echo "$REGISTER_OUT" | grep -oE '(AccessDeniedException|ValidationException).*' || echo "$REGISTER_OUT")

  This is ${GATE_MSG}

  Endpoint verification succeeded (${TOOL_COUNT} tools over SigV4), so the
  URL convention and auth are confirmed working. Once unblocked, re-run
  this script — or register manually:

  ┌─────────────────────────────────────────────────────────────────────┐
  │ Manual Registration (DevOps Agent console, ${REGION})               │
  ├─────────────────────────────────────────────────────────────────────┤
  │ A. Capability Providers → MCP Server → Register                     │
  │    Name:           ${SERVICE_NAME}
  │    Endpoint:       ${MCP_ENDPOINT}
  │    Description:    Deterministic backend diagnostics tools          │
  │                    (read-only): service health, Lambda stats,       │
  │                    queue stats, DynamoDB/Aurora health, canary      │
  │                    results, recent alarms                           │
  │    Authentication: AWS SigV4                                        │
  │    SigV4 region:   ${REGION}
  │    SigV4 service:  bedrock-agentcore                                │
  │    Role ARN:       ${REGISTRATION_ROLE_ARN}
  │ B. Agent Space '${PLATFORM_SPACE_ID}'
  │    → Capabilities tab → MCP Servers → Add                           │
  │    → select '${SERVICE_NAME}', enable all ${TOOL_COUNT} tools → Add
  └─────────────────────────────────────────────────────────────────────┘
  (Note: the console calls the same API, so the account gate may block
  the console flow too — in that case an account exemption is required.)

EOF
      exit 2
    fi
    echo "ERROR: register-service failed:" >&2
    echo "$REGISTER_OUT" >&2
    exit 1
  fi
  SERVICE_ID=$(echo "$REGISTER_OUT" | jq -r '.serviceId')
  echo "  ✓ Registered new service: ${SERVICE_ID}"
fi

# ─── Step 3: Associate to the platform space (idempotent) ───────────────────
echo ""
echo "Step 3: Associate to the platform space..."

EXISTING_ASSOC_ID=$(aws_cmd devops-agent list-associations \
  --agent-space-id "$PLATFORM_SPACE_ID" \
  --query "associations[?serviceId=='${SERVICE_ID}'].associationId | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ -n "$EXISTING_ASSOC_ID" && "$EXISTING_ASSOC_ID" != "None" ]]; then
  echo "  ✓ Association already exists: ${EXISTING_ASSOC_ID}"
else
  # The mcpserversigv4 association config requires the tool allowlist —
  # use the live tools/list captured in Step 1.
  ASSOC_CONFIG=$(jq -n --argjson tools "$TOOL_NAMES" '{mcpserversigv4: {tools: $tools}}')
  ASSOC_OUT=$(aws_cmd devops-agent associate-service \
    --agent-space-id "$PLATFORM_SPACE_ID" \
    --service-id "$SERVICE_ID" \
    --configuration "$ASSOC_CONFIG" \
    --output json)
  ASSOC_ID=$(echo "$ASSOC_OUT" | jq -r '.association.associationId')
  echo "  ✓ Association created: ${ASSOC_ID} (status: $(echo "$ASSOC_OUT" | jq -r '.association.status // "unknown"'), ${TOOL_COUNT} tools)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✓ diagnostics_mcp registered as an MCP capability provider in the"
echo "  platform space (${TOOL_COUNT} tools)."
echo "  Verify: create a chat in the platform space asking it to check"
echo "  backend service health — it should call tool_get_service_health."
echo "═══════════════════════════════════════════════════════════════════"
