#!/usr/bin/env bash
# register-fallback-agents.sh — Register the self-managed fallback agents
# (backend_devops_agent, backend_kb_agent — Strands A2A servers on Bedrock
# AgentCore Runtime) as remote A2A agents in the APP-TEAM Agent Space.
#
# ════════════════════════════════════════════════════════════════════════
#  ⚠ ALTERNATE (A2A) VARIANT — NOT the primary fallback registration.
#
#  The PRIMARY link is the MCP variant: scripts/register-fallback-agents-mcp.sh
#  (mcpserversigv4, SigV4 service bedrock-agentcore, single `investigate`
#  tool per agent).
#
#  Why A2A was demoted (2026-07): the `remoteagentsigv4` registration this
#  script performs is blocked by the account-allowlist gate, and no
#  authorization/exemption process for remote-agent registration could be
#  found — whereas the MCP path has a known unblock process ("third-party
#  MCP access", security review in docs/security/mcp-security-review.md).
#  The agent containers are dual-protocol (SERVE_PROTOCOL env var); to use
#  this A2A variant again, redeploy agents/infra with
#  protocolConfiguration 'A2A' + SERVE_PROTOCOL=A2A on both runtimes.
#
#  This script is kept intact and idempotent as the fallback: everything
#  below still works up to the account gate.
# ════════════════════════════════════════════════════════════════════════
#
# Supersedes register-remote-agents.sh (which guessed at nonexistent CLI
# commands). Mechanism verified against the live service model + endpoints
# (2026-07):
#   • AgentCore A2A runtimes are invoked SigV4-signed (service
#     "bedrock-agentcore") on the regional data plane:
#       card:   GET  https://bedrock-agentcore.{region}.amazonaws.com/
#               runtimes/{urlencoded-runtime-arn}/invocations/.well-known/agent-card.json
#       invoke: POST .../runtimes/{urlencoded-runtime-arn}/invocations
#     (qualifier defaults to DEFAULT; both verified live with SigV4).
#   • Registration uses the `remoteagentsigv4` service type — serviceDetails:
#       {"remoteagentsigv4": {name, endpoint: <card URL>, description,
#        authorizationConfig: {region, service: "bedrock-agentcore",
#        roleArn: <trust role>}}}
#     The trust role aiops-poc-remote-agent-registration (agents/infra CDK)
#     trusts aidevops.amazonaws.com and grants
#     bedrock-agentcore:InvokeAgentRuntime.
#   • Association config for remoteagentsigv4 is an empty object:
#       {"remoteagentsigv4": {}}
#
# Honors /aiops-poc/peer (devops | kb | both) like its predecessor.
#
# ACCOUNT GATE (as of 2026-07): register-service for remoteagentsigv4 fails
# in this account with:
#   AccessDeniedException: Account 333333333333 is not authorized. Only
#   external accounts and exempted accounts are allowed at this time.
# Everything up to that point (endpoint verification) still runs; if the
# gate fires, the script prints pre-filled manual console steps and exits 2.
# Re-run once the account is exempted; the script is idempotent throughout.
#
# Usage:
#   scripts/register-fallback-agents.sh [--profile PROFILE] [--region REGION] [--peer devops|kb|both]
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
      echo "Registers the AgentCore fallback agents as remote A2A agents"
      echo "(remoteagentsigv4) in the app-team Agent Space."
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

# AgentCore data-plane agent-card URL for a runtime (SigV4-signed GET;
# qualifier defaults to DEFAULT when omitted).
card_url() {
  echo "https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/$(urlencode "$1")/invocations/.well-known/agent-card.json"
}

# SigV4-signed GET against the AgentCore data plane (endpoint verification).
sigv4_get() {
  URL="$1" PROFILE="$PROFILE" REGION="$REGION" python3 - <<'PYEOF'
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
    with urllib.request.urlopen(r, timeout=60) as resp:
        print(resp.read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write(f"HTTP {e.code}: {e.read().decode()[:300]}\n")
    sys.exit(1)
PYEOF
}

echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║  DevOps Agent — AgentCore fallback agents → app-team space       ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Profile:        ${PROFILE}"
echo "  Region:         ${REGION}"
echo "  Peer:           ${PEER}"
echo "  App-team space: ${APP_TEAM_SPACE_ID}"
echo "  Trust role:     ${REGISTRATION_ROLE_ARN}"
echo ""

GATE_BLOCKED=false
MANUAL_STEPS=""

# register_agent <ssm-name> <service-name> <description>
register_agent() {
  local ssm_name="$1" service_name="$2" description="$3"

  local runtime_arn card
  runtime_arn=$(get_runtime_arn "$ssm_name")
  card=$(card_url "$runtime_arn")

  echo "── ${service_name} ──────────────────────────────────────────────────"
  echo "  Runtime ARN: ${runtime_arn}"
  echo "  Card URL:    ${card}"

  # Step 1: verify the agent card (read-only, SigV4)
  local card_json card_name
  if card_json=$(sigv4_get "$card"); then
    card_name=$(echo "$card_json" | jq -r '.name // empty')
    echo "  ✓ Agent card fetched with SigV4 (name: ${card_name})"
  else
    echo "ERROR: could not fetch the agent card for ${service_name}." >&2
    exit 1
  fi

  # Step 2: register the service (idempotent by name; account-gated)
  local service_id
  service_id=$(aws_cmd devops-agent list-services \
    --filter-service-type remoteagentsigv4 \
    --query "services[?name=='${service_name}'].serviceId | [0]" \
    --output text 2>/dev/null || echo "None")

  if [[ -n "$service_id" && "$service_id" != "None" ]]; then
    echo "  ✓ Reusing existing service: ${service_id}"
  else
    local service_details register_out register_rc
    service_details=$(jq -n \
      --arg name "$service_name" \
      --arg endpoint "$card" \
      --arg description "$description" \
      --arg region "$REGION" \
      --arg role_arn "$REGISTRATION_ROLE_ARN" \
      '{remoteagentsigv4: {name: $name, endpoint: $endpoint, description: $description,
        authorizationConfig: {region: $region, service: "bedrock-agentcore", roleArn: $role_arn}}}')

    set +e
    register_out=$(aws_cmd devops-agent register-service \
      --service remoteagentsigv4 \
      --name "$service_name" \
      --service-details "$service_details" \
      --output json 2>&1)
    register_rc=$?
    set -e

    if [[ $register_rc -ne 0 ]]; then
      if echo "$register_out" | grep -q "not authorized. Only external accounts"; then
        echo "  ✗ BLOCKED by the account gate:"
        echo "    $(echo "$register_out" | grep -o 'AccessDeniedException.*' || echo "$register_out")"
        GATE_BLOCKED=true
        MANUAL_STEPS+="
  ┌─────────────────────────────────────────────────────────────────────┐
  │ Manual Registration: ${service_name}
  ├─────────────────────────────────────────────────────────────────────┤
  │ A. Capability Providers → Remote Agent → Register                   │
  │    Name:                ${service_name}
  │    Agent card endpoint: ${card}
  │    Description:         ${description:0:60}...
  │    Authentication:      AWS SigV4                                   │
  │    SigV4 region:        ${REGION}
  │    SigV4 service:       bedrock-agentcore                           │
  │    Role ARN:            ${REGISTRATION_ROLE_ARN}
  │ B. Agent Space '${APP_TEAM_SPACE_ID}'
  │    → Capabilities tab → Remote Agents → Add                         │
  │    → select '${service_name}' → Add                                 │
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

  # Step 3: associate to the app-team space (idempotent)
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
      --configuration '{"remoteagentsigv4": {}}' \
      --output json)
    assoc_id=$(echo "$assoc_out" | jq -r '.association.associationId')
    echo "  ✓ Association created: ${assoc_id} (status: $(echo "$assoc_out" | jq -r '.association.status // "unknown"'))"
  fi
  echo ""
}

if [[ "$PEER" == "devops" || "$PEER" == "both" ]]; then
  register_agent "backend-devops-agent" "aiops-poc-backend-devops-agent" \
    "Fallback runbook-consultation agent (Strands on AgentCore, A2A). Consults documented PetAdoptions backend runbooks/playbooks (Agent Skills) and returns documented likely root causes, the checks the owning team should run, and documented remediation guidance. No live telemetry."
fi

if [[ "$PEER" == "kb" || "$PEER" == "both" ]]; then
  register_agent "backend-kb-agent" "aiops-poc-backend-kb-agent" \
    "Fallback KB-grounded consultation agent (Strands + Bedrock Knowledge Base on AgentCore, A2A). Checks the PetAdoptions architecture corpus, returns documented likely root causes with citations plus the checks the owning team should run, and escalates a summary via SNS. No live telemetry."
fi

if [[ "$GATE_BLOCKED" == "true" ]]; then
  cat <<EOF
═══════════════════════════════════════════════════════════════════════
✗ Registration is blocked by the account allowlist gate.

Endpoint verification succeeded — both the URL convention and SigV4 auth
are confirmed working. Once the account exemption lands, re-run:

  scripts/register-fallback-agents.sh --peer ${PEER}

Or register manually in the DevOps Agent console (${REGION}):
${MANUAL_STEPS}

(Note: the console calls the same API, so the account gate may block the
console flow too — in that case the account exemption is required.)
═══════════════════════════════════════════════════════════════════════
EOF
  exit 2
fi

echo "═══════════════════════════════════════════════════════════════════"
echo "✓ Fallback agents registered as remote A2A agents in app-team."
echo "  Verify: scripts/test-fallback.sh --profile ${PROFILE}"
echo "═══════════════════════════════════════════════════════════════════"
