#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# chaos/scripts/inject.sh — Apply exactly one fault to PetAdoptions
#
# Usage:
#   ./chaos/scripts/inject.sh <fault-id> --confirm [--force] [--profile <name>] [--region <region>]
#
# Fault IDs:
#   checkout-degraded  payments-error  payments-crash  db-overload
#   ddb-throttle  status-consumer-off  search-crash  ui-no-scale
#
# Resources are resolved from SSM (/petstore/* and /aiops-poc/workload/*).
# Records active fault in /aiops-poc/active-scenario.
# Refuses to inject if another fault is already active (use --force to override).
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# The target region and both workload profiles come from the Config_Resolver —
# the one shared location that reads config/accounts.json (Requirements 2.3,
# 2.6). They are resolved after argument parsing, below, so that --profile and
# --region sit at the top of the precedence chain.
source "$REPO_ROOT/scripts/lib/config.sh"

FORCE=false
PROFILE_FLAG=""
REGION_FLAG=""
FAULT_ID=""
CONFIRMED=false

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm)
      CONFIRMED=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --profile)
      PROFILE_FLAG="$2"
      shift 2
      ;;
    --region)
      REGION_FLAG="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 <fault-id> --confirm [--force] [--profile <name>] [--region <region>]"
      echo ""
      echo "Fault IDs: checkout-degraded, payments-error, payments-crash, db-overload,"
      echo "           ddb-throttle, status-consumer-off, search-crash, ui-no-scale"
      echo ""
      echo "--confirm is required: every fault causes real, customer-visible impact"
      echo "on the target deployment, so injection never runs on an unadorned command."
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$FAULT_ID" ]]; then
        FAULT_ID="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$FAULT_ID" ]]; then
  echo "ERROR: No fault-id provided." >&2
  echo "Usage: $0 <fault-id> --confirm [--force] [--profile <name>] [--region <region>]" >&2
  exit 1
fi

# --- Future-enhancement guard (fail fast, no AWS calls) ---
# checkout-degraded, db-overload and payments-error rely on the upstream app's
# built-in chaos/degradation/simulator HTTP endpoints, which are NOT present in
# the deployed PetAdoptions container images (an in-VPC probe returned HTTP 404).
# Enabling them would require forking + rebuilding two upstream microservices —
# deliberately out of scope to preserve the "unforked upstream" fidelity rule.
# The injection logic below is kept intact for a future chaos-enabled image;
# until then, give the operator a clear message instead of a raw curl 404 abort.
case "$FAULT_ID" in
  checkout-degraded|db-overload|payments-error)
    echo "Fault '$FAULT_ID' is a FUTURE ENHANCEMENT: it needs the upstream app's" >&2
    echo "chaos/degradation/simulator endpoints, which aren't in the deployed images" >&2
    echo "(see docs/scenarios.md#future-enhancements). Not runnable on this deployment." >&2
    exit 1
    ;;
esac

# --- Resolve region and profiles (flag > env > config file > template) ---
config::init
config::resolve ops.region "$REGION_FLAG"
DEFAULT_REGION="$(config::get ops.region)"
BE_PROFILE="$(config::get backend.profile)"
FE_PROFILE="$(config::get frontend.profile)"

# Determine which account/profile this fault targets
case "$FAULT_ID" in
  checkout-degraded|payments-error|payments-crash|db-overload|ddb-throttle|status-consumer-off|search-crash)
    TARGET_PROFILE="${PROFILE_FLAG:-$BE_PROFILE}"
    ;;
  ui-no-scale)
    TARGET_PROFILE="${PROFILE_FLAG:-$FE_PROFILE}"
    ;;
  *)
    echo "ERROR: Unknown fault-id: $FAULT_ID" >&2
    echo "Valid: checkout-degraded, payments-error, payments-crash, db-overload," >&2
    echo "       ddb-throttle, status-consumer-off, search-crash, ui-no-scale" >&2
    exit 1
    ;;
esac

# --- Confirmation gate (mirrors scripts/destroy-all.sh --confirm) ---
# Every fault causes real, customer-visible impact on the target deployment
# (FIS task-stop, DynamoDB capacity cut, autoscaling pin), so injection never
# runs on an unadorned command — a human must type the flag. Runs before any
# AWS call. restore.sh is deliberately NOT gated.
if [[ "$CONFIRMED" != "true" ]]; then
  echo "ERROR: Refusing to inject '$FAULT_ID' without --confirm." >&2
  echo "" >&2
  echo "This fault causes real, customer-visible impact and pages the agents." >&2
  echo "If you are sure, re-run with:" >&2
  echo "  $0 $FAULT_ID --confirm" >&2
  echo "" >&2
  echo "(To demo the trigger chain without breaking anything, use" >&2
  echo " ./chaos/scripts/trigger-alarm.sh instead — it auto-reverts.)" >&2
  exit 1
fi

TARGET_REGION="${REGION_FLAG:-$DEFAULT_REGION}"
AWS="aws --profile $TARGET_PROFILE --region $TARGET_REGION"

# For active-scenario marker we always use BE profile (marker lives in BE account)
MARKER_PROFILE="${PROFILE_FLAG:-$BE_PROFILE}"
MARKER_AWS="aws --profile $MARKER_PROFILE --region $TARGET_REGION"

echo "=== Chaos inject: $FAULT_ID ==="
echo "    Profile: $TARGET_PROFILE | Region: $TARGET_REGION"

# --- State check: is another fault already active? ---
ACTIVE_SCENARIO=$($MARKER_AWS ssm get-parameter \
  --name "/aiops-poc/active-scenario" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "none")

if [[ "$ACTIVE_SCENARIO" != "none" && "$ACTIVE_SCENARIO" != "" ]]; then
  if [[ "$FORCE" == "true" ]]; then
    echo "WARNING: Overriding active scenario '$ACTIVE_SCENARIO' (--force)" >&2
  else
    echo "ERROR: Another fault is already active: $ACTIVE_SCENARIO" >&2
    echo "       Use --force to override, or restore first:" >&2
    echo "       ./chaos/scripts/restore.sh $ACTIVE_SCENARIO" >&2
    exit 1
  fi
fi

# --- Helper: resolve SSM parameter ---
ssm_get() {
  local name="$1"
  local profile="${2:-$TARGET_PROFILE}"
  aws --profile "$profile" --region "$TARGET_REGION" ssm get-parameter \
    --name "$name" --query "Parameter.Value" --output text
}

# Helper: resolve SSM parameter, empty on missing (for optional params)
ssm_get_opt() {
  local name="$1"
  local profile="${2:-$TARGET_PROFILE}"
  aws --profile "$profile" --region "$TARGET_REGION" ssm get-parameter \
    --name "$name" --query "Parameter.Value" --output text 2>/dev/null || echo ""
}

# Helper: strip a URL to its origin (scheme://host[:port]).
# The /petstore/* URL params carry API paths (e.g. paymentapiurl ends in
# /api/completeadoption), but the chaos/degradation/simulator endpoints are
# served at the service root — same host:port, no path prefix.
url_origin() {
  echo "$1" | sed -E 's#^(https?://[^/]+).*#\1#'
}

# Helper: resolve the FE petsite ECS cluster + service names.
# Primary source: SSM params published by FrontendStack. Fallback: discovery
# via ecs list-clusters/list-services (older FE deploys without the params).
resolve_fe_ecs() {
  FE_CLUSTER=$(ssm_get_opt "/aiops-poc/workload/fe-ecs-cluster")
  FE_SERVICE=$(ssm_get_opt "/aiops-poc/workload/fe-ecs-service")

  if [[ -z "$FE_CLUSTER" || "$FE_CLUSTER" == "None" ]]; then
    echo "  SSM param /aiops-poc/workload/fe-ecs-cluster missing — discovering cluster..." >&2
    FE_CLUSTER=$($AWS ecs list-clusters \
      --query "clusterArns[?contains(@, 'petsite')] | [0]" --output text | awk -F'/' '{print $NF}')
  fi
  if [[ -z "$FE_SERVICE" || "$FE_SERVICE" == "None" ]]; then
    echo "  SSM param /aiops-poc/workload/fe-ecs-service missing — discovering service..." >&2
    FE_SERVICE=$($AWS ecs list-services --cluster "$FE_CLUSTER" \
      --query "serviceArns[?contains(@, 'petsite')] | [0]" --output text | awk -F'/' '{print $NF}')
  fi

  if [[ -z "$FE_CLUSTER" || "$FE_CLUSTER" == "None" || -z "$FE_SERVICE" || "$FE_SERVICE" == "None" ]]; then
    echo "  ERROR: Could not resolve FE petsite ECS cluster/service." >&2
    exit 1
  fi
}

# --- Inject functions per fault-id ---

inject_checkout_degraded() {
  echo "  Injecting: payforadoption degradation (latency 3000ms)..."
  local url
  # paymentapiurl carries the /api/completeadoption path — the degradation
  # endpoints live at the service root, so strip to origin.
  url=$(url_origin "$(ssm_get "/petstore/paymentapiurl")")

  curl -sf -X POST "$url/degradation/enable" \
    -H "Content-Type: application/json" \
    -d '{"latency_ms": 3000}' \
    -o /dev/null -w "  HTTP %{http_code}\n"

  echo "  Verified: degradation enabled"
}

inject_payments_error() {
  echo "  Injecting: payforadoption chaos (error_rate 0.5)..."
  local url
  # paymentapiurl carries the /api/completeadoption path — the chaos
  # endpoints live at the service root, so strip to origin.
  url=$(url_origin "$(ssm_get "/petstore/paymentapiurl")")

  curl -sf -X POST "$url/chaos/enable" \
    -H "Content-Type: application/json" \
    -d '{"error_rate": 0.5}' \
    -o /dev/null -w "  HTTP %{http_code}\n"

  echo "  Verified: chaos mode enabled"
}

inject_payments_crash() {
  echo "  Injecting: FIS experiment payments-crash (stop payforadoption ECS tasks)..."

  # Look up the FIS experiment template
  local template_id
  template_id=$($AWS fis list-experiment-templates \
    --query "experimentTemplates[?tags.Name=='payments-crash'].id | [0]" \
    --output text 2>/dev/null || true)

  if [[ -z "$template_id" || "$template_id" == "None" ]]; then
    # Try by description
    template_id=$($AWS fis list-experiment-templates \
      --query "experimentTemplates[?contains(description, 'payments-crash')].id | [0]" \
      --output text 2>/dev/null || true)
  fi

  if [[ -z "$template_id" || "$template_id" == "None" ]]; then
    echo "  ERROR: FIS experiment template 'payments-crash' not found." >&2
    echo "  Deploy the overlay (task 2.4) first." >&2
    exit 1
  fi

  local experiment_id
  experiment_id=$($AWS fis start-experiment \
    --experiment-template-id "$template_id" \
    --query "experiment.id" --output text)

  echo "  FIS experiment started: $experiment_id"

  # Save experiment id for restore
  $MARKER_AWS ssm put-parameter \
    --name "/aiops-poc/chaos/payments-crash-experiment" \
    --value "$experiment_id" \
    --type String --overwrite > /dev/null
}

inject_db_overload() {
  echo "  Injecting: Aurora lock blocking via petlistadoptions simulator..."
  local url
  # petlistadoptionsurl carries the /api/adoptionlist/ path — the simulator
  # endpoints live at the service root, so strip to origin.
  url=$(url_origin "$(ssm_get "/petstore/petlistadoptionsurl")")

  curl -sf -X POST "$url/simulate/lockblocking" \
    -H "Content-Type: application/json" \
    -o /dev/null -w "  HTTP %{http_code}\n" || {
      echo "  WARNING: lockblocking endpoint returned non-success (may still be injecting)" >&2
    }

  echo "  Verified: lock blocking simulation started"
}

inject_ddb_throttle() {
  echo "  Injecting: reduce DynamoDB provisioned capacity to 1 RCU / 1 WCU..."

  # Resolve the DynamoDB table name
  local table_name
  table_name=$(ssm_get "/petstore/dynamodbtablename")

  # Save current capacity for restore
  local current_rcu current_wcu
  current_rcu=$($AWS dynamodb describe-table --table-name "$table_name" \
    --query "Table.ProvisionedThroughput.ReadCapacityUnits" --output text)
  current_wcu=$($AWS dynamodb describe-table --table-name "$table_name" \
    --query "Table.ProvisionedThroughput.WriteCapacityUnits" --output text)

  echo "  Current capacity: RCU=$current_rcu, WCU=$current_wcu"

  # Save originals to SSM for idempotent restore
  $MARKER_AWS ssm put-parameter \
    --name "/aiops-poc/chaos/ddb-original-rcu" \
    --value "$current_rcu" \
    --type String --overwrite > /dev/null
  $MARKER_AWS ssm put-parameter \
    --name "/aiops-poc/chaos/ddb-original-wcu" \
    --value "$current_wcu" \
    --type String --overwrite > /dev/null
  $MARKER_AWS ssm put-parameter \
    --name "/aiops-poc/chaos/ddb-table-name" \
    --value "$table_name" \
    --type String --overwrite > /dev/null

  # Reduce to minimum
  $AWS dynamodb update-table --table-name "$table_name" \
    --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 > /dev/null

  echo "  Capacity reduced to RCU=1, WCU=1 (original saved to SSM)"
}

inject_status_consumer_off() {
  echo "  Injecting: disable the status-update queue's SQS event source mapping..."

  # Resolve the status-update queue from the SSM contract, then find the
  # Lambda event source mapping consuming it. Matching by queue ARN is
  # robust to the consumer function's name (which is deployment-generated —
  # in the live deployment it is NOT called "StatusUpdater").
  local queue_url queue_arn uuid
  queue_url=$(ssm_get "/petstore/queueurl")
  queue_arn=$($AWS sqs get-queue-attributes --queue-url "$queue_url" \
    --attribute-names QueueArn --query "Attributes.QueueArn" --output text)

  uuid=$($AWS lambda list-event-source-mappings \
    --event-source-arn "$queue_arn" \
    --query "EventSourceMappings[0].UUID" --output text 2>/dev/null || true)

  if [[ -z "$uuid" || "$uuid" == "None" ]]; then
    echo "  ERROR: No event source mapping found for queue $queue_arn." >&2
    exit 1
  fi

  # Save UUID for restore
  $MARKER_AWS ssm put-parameter \
    --name "/aiops-poc/chaos/status-updater-esm-uuid" \
    --value "$uuid" \
    --type String --overwrite > /dev/null

  # Disable the mapping
  $AWS lambda update-event-source-mapping --uuid "$uuid" --no-enabled > /dev/null

  echo "  Event source mapping disabled: $uuid"
}

inject_search_crash() {
  echo "  Injecting: FIS experiment search-crash (stop petsearch ECS tasks)..."

  local template_id
  template_id=$($AWS fis list-experiment-templates \
    --query "experimentTemplates[?tags.Name=='search-crash'].id | [0]" \
    --output text 2>/dev/null || true)

  if [[ -z "$template_id" || "$template_id" == "None" ]]; then
    template_id=$($AWS fis list-experiment-templates \
      --query "experimentTemplates[?contains(description, 'search-crash')].id | [0]" \
      --output text 2>/dev/null || true)
  fi

  if [[ -z "$template_id" || "$template_id" == "None" ]]; then
    echo "  ERROR: FIS experiment template 'search-crash' not found." >&2
    echo "  Deploy the overlay (task 2.4) first." >&2
    exit 1
  fi

  local experiment_id
  experiment_id=$($AWS fis start-experiment \
    --experiment-template-id "$template_id" \
    --query "experiment.id" --output text)

  echo "  FIS experiment started: $experiment_id"

  $MARKER_AWS ssm put-parameter \
    --name "/aiops-poc/chaos/search-crash-experiment" \
    --value "$experiment_id" \
    --type String --overwrite > /dev/null
}

inject_ui_no_scale() {
  echo "  Injecting: pin petsite autoscaling MaxCapacity to current DesiredCapacity..."

  # Resolve petsite ECS cluster/service names from SSM (FE account),
  # falling back to discovery — sets FE_CLUSTER / FE_SERVICE.
  resolve_fe_ecs
  local cluster_name="$FE_CLUSTER"
  local service_name="$FE_SERVICE"
  echo "  FE target: cluster=$cluster_name service=$service_name"

  # Get current desired count
  local desired
  desired=$($AWS ecs describe-services --cluster "$cluster_name" --services "$service_name" \
    --query "services[0].desiredCount" --output text)

  echo "  Current desired count: $desired"

  # Resolve the Application Auto Scaling resource ID
  local resource_id="service/${cluster_name}/${service_name}"

  # Get current max capacity for restore
  local current_max
  current_max=$($AWS application-autoscaling describe-scalable-targets \
    --service-namespace ecs \
    --resource-ids "$resource_id" \
    --query "ScalableTargets[0].MaxCapacity" --output text 2>/dev/null || echo "")

  if [[ -z "$current_max" || "$current_max" == "None" ]]; then
    echo "  ERROR: Could not find autoscaling target for petsite." >&2
    echo "  Ensure petsite is deployed with autoscaling in FE account." >&2
    exit 1
  fi

  echo "  Current max capacity: $current_max"

  # Save original max to SSM (use BE profile for marker storage)
  $MARKER_AWS ssm put-parameter \
    --name "/aiops-poc/chaos/ui-original-max-capacity" \
    --value "$current_max" \
    --type String --overwrite > /dev/null

  # Pin max to current desired
  $AWS application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id "$resource_id" \
    --scalable-dimension "ecs:service:DesiredCount" \
    --max-capacity "$desired" > /dev/null

  echo "  MaxCapacity pinned to $desired (original $current_max saved to SSM)"
}

# --- Execute the injection ---
case "$FAULT_ID" in
  checkout-degraded)   inject_checkout_degraded ;;
  payments-error)      inject_payments_error ;;
  payments-crash)      inject_payments_crash ;;
  db-overload)         inject_db_overload ;;
  ddb-throttle)        inject_ddb_throttle ;;
  status-consumer-off) inject_status_consumer_off ;;
  search-crash)        inject_search_crash ;;
  ui-no-scale)         inject_ui_no_scale ;;
esac

# --- Record active fault in SSM ---
$MARKER_AWS ssm put-parameter \
  --name "/aiops-poc/active-scenario" \
  --value "$FAULT_ID" \
  --type String --overwrite > /dev/null

echo ""
echo "=== Fault '$FAULT_ID' injected successfully ==="
echo ""
echo "To restore:"
echo "  ./chaos/scripts/restore.sh $FAULT_ID"
