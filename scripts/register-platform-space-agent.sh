#!/usr/bin/env bash
# register-platform-space-agent.sh — Register the platform DevOps Agent Space
# as a remote A2A agent in the app-team space (space-to-space delegation).
#
# ════════════════════════════════════════════════════════════════════════
#  ⚠ ALTERNATE (A2A) VARIANT — NOT the primary space-to-space link.
#
#  The PRIMARY link is the MCP variant: scripts/register-platform-space-mcp.sh
#  (mcpserversigv4, tokenless SigV4 + X-Agent-Space-Id customHeader).
#
#  Why A2A was demoted (2026-07): the `remoteagent` registration this
#  script performs is blocked by the account-allowlist gate, and no
#  authorization/exemption process for remote-agent registration could be
#  found — whereas the MCP path has a known unblock process ("third-party
#  MCP access", security review in docs/security/mcp-security-review.md).
#  A2A also requires space-bound bearer tokens (60-day expiry + rotation);
#  the MCP variant needs no tokens at all.
#
#  This script is kept intact and idempotent as the fallback: everything
#  below still works up to the account gate, and both links can coexist.
# ════════════════════════════════════════════════════════════════════════
#
# Mechanism (verified against the live API, 2026-07):
#   • The platform space's A2A endpoint is the shared regional DevOps Agent
#     remote server: https://connect.aidevops.{region}.api.aws
#     (agent card at /.well-known/agent-card.json, A2A v1.0 HTTP+JSON at
#     /a2a/* — e.g. POST /a2a/message:send with an A2A-Version: 1.0 header).
#   • Space routing: a Bearer access token is bound to exactly one space, so
#     bearer auth routes to the platform space with no extra headers. SigV4
#     auth does NOT work for space-to-space registration: the shared endpoint
#     then needs an X-Agent-Space-Id header, and the remoteagentsigv4
#     registration type has no customHeaders support (verified against the
#     service model), so the DevOps Agent caller could never inject it.
#   • Access tokens ARE manageable via the control-plane HTTP API
#     (cp.aidevops.{region}.api.aws, SigV4 service "aidevops") even though
#     the AWS CLI has no commands for them:
#       PATCH /v1/agentspaces/{id}                       {"accessTokensEnabled": true}
#       POST  /v1/agentspaces/{id}/access-tokens         {"tokenName", "scopes":
#             ["agent:operate"|"agent:read"], "clientType": "AGENT"|"HUMAN",
#             "expirationDays"}  → accessToken (only shown once)
#       GET   /v1/agentspaces/{id}/access-tokens
#       POST  /v1/agentspaces/{id}/access-tokens/{tid}/rotate  → newAccessToken
#   • Registration itself: aws devops-agent register-service --service
#     remoteagent (bearerToken auth) + associate-service to the app-team
#     space with configuration {"remoteagent": {}}.
#
# ACCOUNT GATE (as of 2026-07): register-service for BOTH remoteagent and
# remoteagentsigv4 fails in this account with:
#   AccessDeniedException: Account 333333333333 is not authorized. Only
#   external accounts and exempted accounts are allowed at this time.
# (same gate as mcpserver). Everything up to that point — token creation,
# secret storage, endpoint verification — is automated here; if the gate
# fires, the script prints pre-filled manual console steps and exits 2.
# Re-run once the account is exempted; the script is idempotent throughout.
#
# Usage:
#   scripts/register-platform-space-agent.sh [--profile PROFILE] [--region REGION] [--rotate-token]
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

SECRET_NAME="aiops-poc/platform-space-a2a-token"
SERVICE_NAME="aiops-poc-platform-space"
TOKEN_NAME="aiops-poc-space-to-space"
AGENT_DESCRIPTION="Platform DevOps Agent Space (aiops-poc-platform). Investigates backend/platform services of PetAdoptions: ECS cluster PetsiteECS-cluster, Aurora, DynamoDB, SQS. Delegate platform-domain investigation subtasks here."

# ─── Defaults (flags override the resolved values) ─────────────────────────
PROFILE_FLAG=""
REGION_FLAG=""
ROTATE_TOKEN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE_FLAG="$2"; shift 2 ;;
    --region)  REGION_FLAG="$2"; shift 2 ;;
    --rotate-token) ROTATE_TOKEN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--profile PROFILE] [--region REGION] [--rotate-token]"
      echo ""
      echo "Registers the platform Agent Space as a remote A2A agent in the"
      echo "app-team space. Creates/stores the space-bound access token in"
      echo "Secrets Manager (${SECRET_NAME})."
      echo ""
      echo "Options:"
      echo "  --profile       AWS CLI profile (default: config/accounts.json → ops.profile)"
      echo "  --region        AWS region (default: config/accounts.json → ops.region)"
      echo "  --rotate-token  Rotate the platform-space access token (new value,"
      echo "                  old value invalidated; secret is updated)"
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

# SigV4-signed call to the DevOps Agent control-plane HTTP API
# (cp.aidevops.{region}.api.aws — access-token operations have no CLI).
cp_api() {
  local method="$1" path="$2" body="${3:-}"
  METHOD="$method" URL="https://cp.aidevops.${REGION}.api.aws${path}" BODY="$body" \
  PROFILE="$PROFILE" REGION="$REGION" python3 - <<'PYEOF'
import json, os, sys, urllib.request, urllib.error
import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

method, url, body = os.environ["METHOD"], os.environ["URL"], os.environ["BODY"]
session = boto3.Session(profile_name=os.environ["PROFILE"])
creds = session.get_credentials().get_frozen_credentials()
headers = {"Accept": "application/json"}
data = body.encode() if body else None
if data:
    headers["Content-Type"] = "application/json"
req = AWSRequest(method=method, url=url, data=data, headers=headers)
SigV4Auth(creds, "aidevops", os.environ["REGION"]).add_auth(req)
r = urllib.request.Request(url, data=data, headers=dict(req.headers), method=method)
try:
    with urllib.request.urlopen(r, timeout=60) as resp:
        print(resp.read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write(f"HTTP {e.code}: {e.read().decode()}\n")
    sys.exit(1)
PYEOF
}

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  DevOps Agent — platform space → app-team remote A2A agent       ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Profile: ${PROFILE}"
echo "  Region:  ${REGION}"
echo ""

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
CARD_URL="https://connect.aidevops.${REGION}.api.aws/.well-known/agent-card.json"

echo "  app-team space:  ${APP_TEAM_SPACE_ID}"
echo "  platform space:  ${PLATFORM_SPACE_ID}"
echo "  agent card URL:  ${CARD_URL}"
echo ""

# ─── Step 1: Enable access tokens on the platform space ────────────────────
echo "Step 1: Enable access tokens on the platform space..."
cp_api PATCH "/v1/agentspaces/${PLATFORM_SPACE_ID}" '{"accessTokensEnabled":true}' >/dev/null
echo "  ✓ Access tokens enabled (idempotent)"

# ─── Step 2: Create / reuse / rotate the space-bound token ─────────────────
echo ""
echo "Step 2: Space-bound access token (${TOKEN_NAME})..."

ACTIVE_TOKEN_ID=$(cp_api GET "/v1/agentspaces/${PLATFORM_SPACE_ID}/access-tokens" \
  | jq -r --arg n "$TOKEN_NAME" \
      '.items[] | select(.tokenName == $n and .status == "ACTIVE") | .accessTokenId' \
  | head -n1)

TOKEN_VALUE=""
SECRET_EXISTS=false
if aws_cmd secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  SECRET_EXISTS=true
fi

if [[ -n "$ACTIVE_TOKEN_ID" && "$SECRET_EXISTS" == "true" && "$ROTATE_TOKEN" != "true" ]]; then
  STORED_ID=$(aws_cmd secretsmanager get-secret-value --secret-id "$SECRET_NAME" \
    --query 'SecretString' --output text | jq -r '.token_id // empty')
  if [[ "$STORED_ID" == "$ACTIVE_TOKEN_ID" ]]; then
    TOKEN_VALUE=$(aws_cmd secretsmanager get-secret-value --secret-id "$SECRET_NAME" \
      --query 'SecretString' --output text | jq -r '.token_value')
    echo "  ✓ Reusing active token ${ACTIVE_TOKEN_ID} from Secrets Manager"
  fi
fi

if [[ -z "$TOKEN_VALUE" ]]; then
  if [[ -n "$ACTIVE_TOKEN_ID" ]]; then
    # Active token exists but its value is unknown (or --rotate-token):
    # rotate to obtain a fresh value. Rotation preserves name/scopes.
    echo "  Rotating token ${ACTIVE_TOKEN_ID} to obtain a fresh value..."
    ROTATE_OUT=$(cp_api POST \
      "/v1/agentspaces/${PLATFORM_SPACE_ID}/access-tokens/${ACTIVE_TOKEN_ID}/rotate" '{}')
    TOKEN_VALUE=$(echo "$ROTATE_OUT" | jq -r '.newAccessToken')
    TOKEN_ID=$(echo "$ROTATE_OUT" | jq -r '.accessTokenId')
    EXPIRES=$(echo "$ROTATE_OUT" | jq -r '.expiresAt')
  else
    echo "  Creating token (clientType AGENT, scope agent:operate, 60 days)..."
    CREATE_OUT=$(cp_api POST "/v1/agentspaces/${PLATFORM_SPACE_ID}/access-tokens" \
      "{\"tokenName\":\"${TOKEN_NAME}\",\"scopes\":[\"agent:operate\"],\"clientType\":\"AGENT\",\"expirationDays\":60}")
    TOKEN_VALUE=$(echo "$CREATE_OUT" | jq -r '.accessToken')
    TOKEN_ID=$(echo "$CREATE_OUT" | jq -r '.accessTokenId')
    EXPIRES=$(echo "$CREATE_OUT" | jq -r '.expiresAt')
  fi

  [[ -n "$TOKEN_VALUE" && "$TOKEN_VALUE" != "null" ]] || {
    echo "ERROR: token create/rotate did not return a token value." >&2; exit 1; }

  SECRET_VALUE=$(jq -n \
    --arg token_name "$TOKEN_NAME" \
    --arg token_id "$TOKEN_ID" \
    --arg token_value "$TOKEN_VALUE" \
    --arg agent_space_id "$PLATFORM_SPACE_ID" \
    --arg expires_at "$EXPIRES" \
    '{token_name: $token_name, token_id: $token_id, token_value: $token_value,
      agent_space_id: $agent_space_id, scopes: ["agent:operate"],
      client_type: "AGENT", expires_at: $expires_at}')

  if [[ "$SECRET_EXISTS" == "true" ]]; then
    aws_cmd secretsmanager put-secret-value --secret-id "$SECRET_NAME" \
      --secret-string "$SECRET_VALUE" --query 'Name' --output text >/dev/null
    echo "  ✓ Token ${TOKEN_ID} stored (updated ${SECRET_NAME}), expires ${EXPIRES}"
  else
    aws_cmd secretsmanager create-secret --name "$SECRET_NAME" \
      --description "Space-bound DevOps Agent access token for the platform space A2A endpoint (space-to-space delegation)" \
      --secret-string "$SECRET_VALUE" --query 'Name' --output text >/dev/null
    echo "  ✓ Token ${TOKEN_ID} stored (created ${SECRET_NAME}), expires ${EXPIRES}"
  fi
fi

# ─── Step 3: Verify the A2A endpoint routes to the platform space ──────────
echo ""
echo "Step 3: Verify the A2A endpoint with the token..."

CARD_HTTP=$(curl -s -o /tmp/aiops-platform-card.json -w "%{http_code}" \
  -H "Authorization: Bearer ${TOKEN_VALUE}" "$CARD_URL")
if [[ "$CARD_HTTP" == "200" ]]; then
  echo "  ✓ Agent card fetched (name: $(jq -r '.name' /tmp/aiops-platform-card.json))"
else
  echo "ERROR: agent card fetch returned HTTP ${CARD_HTTP}" >&2
  exit 1
fi

PROBE=$(curl -s -X POST "https://connect.aidevops.${REGION}.api.aws/a2a/message:send" \
  -H "Authorization: Bearer ${TOKEN_VALUE}" \
  -H "Content-Type: application/json" -H "A2A-Version: 1.0" \
  --max-time 90 \
  -d '{"message":{"role":"ROLE_USER","parts":[{"text":"Which agent space is this? One short sentence."}]}}')
PROBE_TEXT=$(echo "$PROBE" | jq -r '.task.artifacts[0].parts[0].text // empty' 2>/dev/null)
if echo "$PROBE_TEXT" | grep -qi "platform"; then
  echo "  ✓ A2A message:send answered from the platform space"
else
  echo "  ⚠ A2A probe response did not clearly identify the platform space:"
  echo "    ${PROBE:0:300}"
fi
rm -f /tmp/aiops-platform-card.json

# ─── Step 4: Register the remote agent (account-gated as of 2026-07) ───────
echo ""
echo "Step 4: Register '${SERVICE_NAME}' (service type: remoteagent)..."

SERVICE_ID=$(aws_cmd devops-agent list-services \
  --filter-service-type remoteagent \
  --query "services[?name=='${SERVICE_NAME}'].serviceId | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ -n "$SERVICE_ID" && "$SERVICE_ID" != "None" ]]; then
  echo "  ✓ Reusing existing service: ${SERVICE_ID}"
else
  SERVICE_DETAILS=$(jq -n \
    --arg name "$SERVICE_NAME" \
    --arg endpoint "$CARD_URL" \
    --arg description "$AGENT_DESCRIPTION" \
    --arg token_name "$TOKEN_NAME" \
    --arg token_value "$TOKEN_VALUE" \
    '{remoteagent: {name: $name, endpoint: $endpoint, description: $description,
      authorizationConfig: {bearerToken: {tokenName: $token_name, tokenValue: $token_value}}}}')

  set +e
  REGISTER_OUT=$(aws_cmd devops-agent register-service \
    --service remoteagent \
    --name "$SERVICE_NAME" \
    --service-details "$SERVICE_DETAILS" \
    --output json 2>&1)
  REGISTER_RC=$?
  set -e

  if [[ $REGISTER_RC -ne 0 ]]; then
    if echo "$REGISTER_OUT" | grep -q "not authorized. Only external accounts"; then
      cat <<EOF

  ✗ BLOCKED: remote agent registration is account-gated:
    $(echo "$REGISTER_OUT" | grep -o 'AccessDeniedException.*' || echo "$REGISTER_OUT")

  Everything else is in place (token created + stored, endpoint verified).
  Once the account is exempted, re-run this script — or register manually:

  ┌─────────────────────────────────────────────────────────────────────┐
  │ Manual Registration (DevOps Agent console, ${REGION})               │
  ├─────────────────────────────────────────────────────────────────────┤
  │ A. Capability Providers → Remote Agent → Register                   │
  │    Name:                ${SERVICE_NAME}
  │    Agent card endpoint: ${CARD_URL}
  │    Description:         Platform DevOps Agent Space — backend/      │
  │                         platform investigations (ECS, Aurora,       │
  │                         DynamoDB, SQS) on delegation                │
  │    Authentication:      Bearer Token                                │
  │    Token:               Secrets Manager ${SECRET_NAME}
  │                         → JSON field "token_value"                  │
  │ B. Agent Space '${APP_TEAM_SPACE_ID}'
  │    → Capabilities tab → Remote Agents → Add                         │
  │    → select '${SERVICE_NAME}' → Add                                 │
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

# ─── Step 5: Associate to the app-team space ───────────────────────────────
echo ""
echo "Step 5: Associate to the app-team space..."

EXISTING_ASSOC_ID=$(aws_cmd devops-agent list-associations \
  --agent-space-id "$APP_TEAM_SPACE_ID" \
  --query "associations[?serviceId=='${SERVICE_ID}'].associationId | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ -n "$EXISTING_ASSOC_ID" && "$EXISTING_ASSOC_ID" != "None" ]]; then
  echo "  ✓ Association already exists: ${EXISTING_ASSOC_ID}"
else
  ASSOC_OUT=$(aws_cmd devops-agent associate-service \
    --agent-space-id "$APP_TEAM_SPACE_ID" \
    --service-id "$SERVICE_ID" \
    --configuration '{"remoteagent": {}}' \
    --output json)
  ASSOC_ID=$(echo "$ASSOC_OUT" | jq -r '.association.associationId')
  ASSOC_STATUS=$(echo "$ASSOC_OUT" | jq -r '.association.status // "unknown"')
  echo "  ✓ Association created: ${ASSOC_ID} (status: ${ASSOC_STATUS})"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✓ Platform space registered as a remote A2A agent in app-team."
echo "  Verify delegation: scripts/test-delegation.sh, or create a chat in"
echo "  the app-team space asking for a platform-domain investigation."
echo "═══════════════════════════════════════════════════════════════════"
