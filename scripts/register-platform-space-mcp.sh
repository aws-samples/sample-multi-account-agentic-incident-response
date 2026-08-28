#!/usr/bin/env bash
# register-platform-space-mcp.sh — Register the platform DevOps Agent Space's
# remote MCP endpoint as an MCP capability provider in the app-team space.
#
# ════════════════════════════════════════════════════════════════════════
#  PRIMARY space-to-space link (app-team → platform), MCP variant.
#  The A2A variant (scripts/register-platform-space-agent.sh) is kept as
#  the ALTERNATE: it is blocked by the harder account-allowlist gate and
#  needs space-bound bearer tokens (60-day expiry). This MCP variant is
#  tokenless (SigV4) and is the path with a known unblock process
#  ("third-party MCP access" — security review in
#  docs/security/mcp-security-review.md covers that process's evidence
#  requirements for our custom MCP; the endpoint here is AWS-operated).
# ════════════════════════════════════════════════════════════════════════
#
# Mechanism (verified against the live API, 2026-07):
#   • The platform space's remote MCP endpoint is the shared regional
#     server: https://connect.aidevops.{region}.api.aws/mcp
#     (stateless streamable HTTP, JSON-RPC: initialize, tools/list, ...).
#   • Space routing — BOTH auth modes verified live:
#       - Bearer space-bound access token → routes implicitly (24 tools
#         with an agent:operate token).
#       - SigV4 (service "aidevops") + X-Agent-Space-Id header → routes
#         explicitly (34 tools with admin credentials).
#     Unlike `remoteagentsigv4`, the `mcpserversigv4` registration type
#     HAS `customHeaders` in its authorizationConfig (verified in the
#     2026-01-01 service model), so the calling DevOps Agent CAN inject
#     X-Agent-Space-Id. That makes SigV4 viable for space-to-space MCP —
#     no access tokens, no expiry, no secret to rotate. This script uses
#     SigV4 only.
#   • Registration: register-service --service mcpserversigv4 with
#     authorizationConfig {region, service: "aidevops", roleArn,
#     customHeaders: {"X-Agent-Space-Id": <platform-space-id>}}.
#   • Association config REQUIRES an explicit tools allowlist
#     ({"mcpserversigv4": {"tools": [...]}}). This script allowlists a
#     curated investigation/chat subset (no space-admin or token-admin
#     tools), intersected with the live tools/list.
#
# ACCOUNT GATES — measured live in this account (2026-07-20):
#   • Plain `mcpserver` (bearer) → AccessDeniedException "Account ... is
#     not authorized. Only external accounts and exempted accounts are
#     allowed at this time." (gate 1, the general capability-registration
#     allowlist — the same gate that blocks remoteagent/remoteagentsigv4).
#   • `mcpserversigv4` → passes gate 1 but hits ValidationException "This
#     account can only register internally allowlisted MCP servers. To
#     register other MCP servers, enable third-party access on your
#     account." (gate 2) — EVEN for the first-party
#     connect.aidevops.{region}.api.aws endpoint. The internal MCP
#     allowlist therefore does not (currently) exempt DevOps Agent's own
#     remote MCP endpoint; "third-party access" must be enabled on the
#     account regardless.
# Endpoint verification runs either way; if a gate fires, the script
# prints the applicable guidance + pre-filled manual console steps and
# exits 2. Re-run once unblocked; the script is idempotent throughout.
#
# POST-GATE REQUIREMENT: the trust role
# (aiops-poc-remote-agent-registration) must carry aidevops permissions so
# the DevOps Agent can call the endpoint through it — added in
# agents/infra (statement InvokeDevopsAgentRemoteMcp); redeploy that stack
# if the check in Step 2 warns.
#
# Usage:
#   scripts/register-platform-space-mcp.sh [--profile PROFILE] [--region REGION]
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

SERVICE_NAME="aiops-poc-platform-space-mcp"
# NOTE: the DevOps Agent RegisterService API caps mcpserversigv4 descriptions
# at 500 chars, so this is the ≤500-char form of the intended copy — it keeps
# the responder's own vocabulary (payments/payforadoption/backend + live state
# verification), marks this the PREFERRED first delegation target, and demotes
# the two fallbacks to knowledge-only.
DESCRIPTION="Live-telemetry investigator INSIDE the PetAdoptions BACKEND account the app-team cannot access: payforadoption (payments/checkout), petsearch, ECS, Aurora, DynamoDB, SQS. Live AWS read access lets it CONFIRM a backend service's live state — task counts, target health, error rates — not just documented guidance. PREFERRED FIRST delegation target when a customer-facing symptom (checkout failing) points at a backend service; prefer over the knowledge-only fallbacks that cannot verify live state."

# Curated delegation tool allowlist: investigation + chat only. The live
# SigV4 tools/list also exposes space-admin and access-token-admin tools
# (create_agent_space, create_access_token, ...) — deliberately excluded.
DELEGATION_TOOLS='["get_agent_space","list_associations","create_investigation","get_task","list_tasks","list_journal_records","list_executions","create_chat","list_chats","chat","investigate","send_message"]'

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
      echo "Registers the platform Agent Space's remote MCP endpoint as an MCP"
      echo "capability provider (mcpserversigv4, tokenless SigV4 + space-routing"
      echo "header) in the app-team space."
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

# ─── Resolve space IDs ──────────────────────────────────────────────────────
APP_TEAM_ARN=$(aws_cmd ssm get-parameter \
  --name "/aiops-poc/agent-spaces/app-team/arn" \
  --query 'Parameter.Value' --output text 2>/dev/null) || {
  echo "ERROR: Could not read /aiops-poc/agent-spaces/app-team/arn from SSM." >&2
  exit 1
}
PLATFORM_ARN=$(aws_cmd ssm get-parameter \
  --name "/aiops-poc/agent-spaces/platform/arn" \
  --query 'Parameter.Value' --output text 2>/dev/null) || {
  echo "ERROR: Could not read /aiops-poc/agent-spaces/platform/arn from SSM." >&2
  exit 1
}
APP_TEAM_SPACE_ID="${APP_TEAM_ARN##*/}"
PLATFORM_SPACE_ID="${PLATFORM_ARN##*/}"
MCP_ENDPOINT="https://connect.aidevops.${REGION}.api.aws/mcp"

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  DevOps Agent — platform space /mcp → app-team (MCP, SigV4)      ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Profile:         ${PROFILE}"
echo "  Region:          ${REGION}"
echo "  app-team space:  ${APP_TEAM_SPACE_ID}"
echo "  platform space:  ${PLATFORM_SPACE_ID}"
echo "  MCP endpoint:    ${MCP_ENDPOINT}"
echo "  Trust role:      ${REGISTRATION_ROLE_ARN}"
echo ""

# ─── Step 1: Verify the MCP endpoint (read-only, SigV4 + space header) ─────
echo "Step 1: Verify the MCP endpoint (SigV4 + X-Agent-Space-Id: initialize + tools/list)..."

TOOLS_JSON=$(URL="$MCP_ENDPOINT" PROFILE="$PROFILE" REGION="$REGION" \
  SPACE_ID="$PLATFORM_SPACE_ID" python3 - <<'PYEOF'
import json, os, sys, urllib.request, urllib.error
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

url = os.environ["URL"]
space_id = os.environ["SPACE_ID"]
session = boto3.Session(profile_name=os.environ["PROFILE"])
creds = session.get_credentials().get_frozen_credentials()

def call(payload):
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json",
               "Accept": "application/json, text/event-stream",
               "X-Agent-Space-Id": space_id}
    req = AWSRequest(method="POST", url=url, data=data, headers=headers)
    SigV4Auth(creds, "aidevops", os.environ["REGION"]).add_auth(req)
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
                            "clientInfo": {"name": "register-platform-space-mcp", "version": "0"}}})
    server = init.get("result", {}).get("serverInfo", {}).get("name", "?")
    tools = call({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    names = [t["name"] for t in tools["result"]["tools"]]
    print(json.dumps({"server": server, "tools": names}))
except urllib.error.HTTPError as e:
    sys.stderr.write(f"HTTP {e.code}: {e.read().decode()[:300]}\n")
    sys.exit(1)
PYEOF
) || { echo "ERROR: MCP endpoint verification failed." >&2; exit 1; }

LIVE_TOOLS=$(echo "$TOOLS_JSON" | jq -c '.tools')
echo "  ✓ MCP server '$(echo "$TOOLS_JSON" | jq -r '.server')' answered with $(echo "$LIVE_TOOLS" | jq 'length') tools"

# Intersect the curated delegation allowlist with the live tool list.
TOOL_NAMES=$(jq -cn --argjson live "$LIVE_TOOLS" --argjson want "$DELEGATION_TOOLS" \
  '$want | map(select(. as $t | $live | index($t)))')
TOOL_COUNT=$(echo "$TOOL_NAMES" | jq 'length')
[[ "$TOOL_COUNT" -gt 0 ]] || { echo "ERROR: none of the curated delegation tools are present in the live tools/list." >&2; exit 1; }
echo "  ✓ Association allowlist: ${TOOL_COUNT} curated investigation/chat tools"
echo "$TOOL_NAMES" | jq -r '.[] | "      • " + .'

# ─── Step 2: Check the trust role has aidevops permissions ─────────────────
echo ""
echo "Step 2: Check trust role aidevops permissions (needed post-registration)..."
ROLE_ACTIONS=$(aws_cmd iam list-role-policies \
  --role-name aiops-poc-remote-agent-registration \
  --query 'PolicyNames' --output json 2>/dev/null | jq -r '.[]' | while read -r p; do
    aws_cmd iam get-role-policy --role-name aiops-poc-remote-agent-registration \
      --policy-name "$p" --query 'PolicyDocument.Statement[].Action' --output json 2>/dev/null
  done | jq -s 'flatten | unique' 2>/dev/null || echo '[]')
if echo "$ROLE_ACTIONS" | jq -e 'map(select(startswith("aidevops:"))) | length > 0' >/dev/null 2>&1; then
  echo "  ✓ Trust role carries aidevops:* permissions"
else
  echo "  ⚠ Trust role has NO aidevops permissions yet — the registered provider"
  echo "    would fail at call time. Redeploy agents/infra (statement"
  echo "    InvokeDevopsAgentRemoteMcp) before relying on this link."
fi

# ─── Step 3: Register the service (idempotent; account-gated) ───────────────
echo ""
echo "Step 3: Register '${SERVICE_NAME}' (service type: mcpserversigv4)..."

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
    --arg space_id "$PLATFORM_SPACE_ID" \
    '{mcpserversigv4: {name: $name, endpoint: $endpoint, description: $description,
      authorizationConfig: {region: $region, service: "aidevops", roleArn: $role_arn,
        customHeaders: {"X-Agent-Space-Id": $space_id}}}}')

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
      GATE_MSG="the account allowlist gate (gate 1) — re-run once the account exemption lands."
    elif echo "$REGISTER_OUT" | grep -q "enable third-party access"; then
      GATE_MSG="the MCP third-party gate (gate 2). Verified live: this fires even
    for the first-party connect.aidevops endpoint — the internal MCP
    allowlist does not exempt DevOps Agent's own remote MCP server.
    'Third-party access' is an account setting not exposed in the CLI/API
    (verified against the service model); enable it via the DevOps Agent
    console account settings or the third-party MCP access process (see
    docs/security/mcp-security-review.md for the security-review evidence
    that process expects). Re-run once enabled."
    fi
    if [[ -n "$GATE_MSG" ]]; then
      cat <<EOF

  ✗ BLOCKED: $(echo "$REGISTER_OUT" | grep -oE '(AccessDeniedException|ValidationException).*' || echo "$REGISTER_OUT")

  This is ${GATE_MSG}

  Endpoint verification succeeded (SigV4 + X-Agent-Space-Id, ${TOOL_COUNT}
  curated tools), so routing and auth are confirmed working. Once
  unblocked, re-run this script — or register manually:

  ┌─────────────────────────────────────────────────────────────────────┐
  │ Manual Registration (DevOps Agent console, ${REGION})               │
  ├─────────────────────────────────────────────────────────────────────┤
  │ A. Capability Providers → MCP Server → Register                     │
  │    Name:           ${SERVICE_NAME}
  │    Endpoint:       ${MCP_ENDPOINT}
  │    Description:    Live-telemetry investigator for the PetAdoptions
  │                    backend account (payforadoption/payments,
  │                    petsearch, ECS, Aurora, DynamoDB, SQS) —
  │                    preferred first delegation target for backend
  │                    root causes                                      │
  │    Authentication: AWS SigV4                                        │
  │    SigV4 region:   ${REGION}
  │    SigV4 service:  aidevops                                         │
  │    Role ARN:       ${REGISTRATION_ROLE_ARN}
  │    Custom header:  X-Agent-Space-Id: ${PLATFORM_SPACE_ID}
  │ B. Agent Space '${APP_TEAM_SPACE_ID}'
  │    → Capabilities tab → MCP Servers → Add                           │
  │    → select '${SERVICE_NAME}', enable the ${TOOL_COUNT} curated tools → Add
  └─────────────────────────────────────────────────────────────────────┘
  (Note: the console calls the same API, so the account gate may block
  the console flow too — in that case the account-level unblock is
  required either way.)

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

# ─── Step 4: Associate to the app-team space (idempotent) ───────────────────
echo ""
echo "Step 4: Associate to the app-team space..."

EXISTING_ASSOC_ID=$(aws_cmd devops-agent list-associations \
  --agent-space-id "$APP_TEAM_SPACE_ID" \
  --query "associations[?serviceId=='${SERVICE_ID}'].associationId | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ -n "$EXISTING_ASSOC_ID" && "$EXISTING_ASSOC_ID" != "None" ]]; then
  echo "  ✓ Association already exists: ${EXISTING_ASSOC_ID}"
else
  # The mcpserversigv4 association config requires the tools allowlist —
  # use the curated set intersected with the live tools/list in Step 1.
  ASSOC_CONFIG=$(jq -n --argjson tools "$TOOL_NAMES" '{mcpserversigv4: {tools: $tools}}')
  ASSOC_OUT=$(aws_cmd devops-agent associate-service \
    --agent-space-id "$APP_TEAM_SPACE_ID" \
    --service-id "$SERVICE_ID" \
    --configuration "$ASSOC_CONFIG" \
    --output json)
  ASSOC_ID=$(echo "$ASSOC_OUT" | jq -r '.association.associationId')
  echo "  ✓ Association created: ${ASSOC_ID} (status: $(echo "$ASSOC_OUT" | jq -r '.association.status // "unknown"'), ${TOOL_COUNT} tools)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✓ Platform space /mcp registered as an MCP capability provider in"
echo "  app-team (${TOOL_COUNT} curated tools, tokenless SigV4)."
echo "  Verify delegation: scripts/test-delegation.sh, or create a chat in"
echo "  the app-team space asking for a platform-domain investigation."
echo "═══════════════════════════════════════════════════════════════════"
