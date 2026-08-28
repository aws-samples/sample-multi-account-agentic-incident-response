#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# chaos/scripts/restore.sh — Revert a fault idempotently
#
# Usage:
#   ./chaos/scripts/restore.sh <fault-id> [--profile <name>] [--region <region>]
#
# Idempotent: safe to call even if the fault isn't currently active.
# Clears /aiops-poc/active-scenario SSM marker.
# Original capacity values are read from SSM (saved by inject.sh).
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# The target region and both workload profiles come from the Config_Resolver —
# the one shared location that reads config/accounts.json (Requirements 2.3,
# 2.6). They are resolved after argument parsing, below, so that --profile and
# --region sit at the top of the precedence chain.
source "$REPO_ROOT/scripts/lib/config.sh"

PROFILE_FLAG=""
REGION_FLAG=""
FAULT_ID=""

# --- Argument parsing ---
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
      echo "Usage: $0 <fault-id> [--profile <name>] [--region <region>]"
      echo ""
      echo "Fault IDs: checkout-degraded, payments-error, payments-crash, db-overload,"
      echo "           ddb-throttle, status-consumer-off, search-crash, ui-no-scale"
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
  echo "Usage: $0 <fault-id> [--profile <name>] [--region <region>]" >&2
  exit 1
fi

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

TARGET_REGION="${REGION_FLAG:-$DEFAULT_REGION}"
AWS="aws --profile $TARGET_PROFILE --region $TARGET_REGION"

# Marker always in BE account
MARKER_PROFILE="${PROFILE_FLAG:-$BE_PROFILE}"
MARKER_AWS="aws --profile $MARKER_PROFILE --region $TARGET_REGION"

echo "=== Chaos restore: $FAULT_ID ==="
echo "    Profile: $TARGET_PROFILE | Region: $TARGET_REGION"

# --- Helper: resolve SSM parameter (returns empty on missing) ---
ssm_get() {
  local name="$1"
  local profile="${2:-$TARGET_PROFILE}"
  aws --profile "$profile" --region "$TARGET_REGION" ssm get-parameter \
    --name "$name" --query "Parameter.Value" --output text 2>/dev/null || echo ""
}

# Helper: delete SSM parameter (idempotent)
ssm_delete() {
  local name="$1"
  $MARKER_AWS ssm delete-parameter --name "$name" 2>/dev/null || true
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
  FE_CLUSTER=$(ssm_get "/aiops-poc/workload/fe-ecs-cluster")
  FE_SERVICE=$(ssm_get "/aiops-poc/workload/fe-ecs-service")

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

# --- Restore functions per fault-id ---

restore_checkout_degraded() {
  echo "  Restoring: disable payforadoption degradation..."
  local url
  url=$(ssm_get "/petstore/paymentapiurl")

  if [[ -z "$url" ]]; then
    echo "  SKIP: Could not resolve payforadoption URL (service may not be deployed)" >&2
    return 0
  fi

  # paymentapiurl carries the /api/completeadoption path — the degradation
  # endpoints live at the service root, so strip to origin.
  url=$(url_origin "$url")
  curl -sf -X POST "$url/degradation/disable" -o /dev/null -w "  HTTP %{http_code}\n" || {
    echo "  WARNING: degradation/disable returned non-success (may already be off)" >&2
  }

  echo "  Degradation mode disabled"
}

restore_payments_error() {
  echo "  Restoring: disable payforadoption chaos..."
  local url
  url=$(ssm_get "/petstore/paymentapiurl")

  if [[ -z "$url" ]]; then
    echo "  SKIP: Could not resolve payforadoption URL (service may not be deployed)" >&2
    return 0
  fi

  # paymentapiurl carries the /api/completeadoption path — the chaos
  # endpoints live at the service root, so strip to origin.
  url=$(url_origin "$url")
  curl -sf -X POST "$url/chaos/disable" -o /dev/null -w "  HTTP %{http_code}\n" || {
    echo "  WARNING: chaos/disable returned non-success (may already be off)" >&2
  }

  echo "  Chaos mode disabled"
}

restore_payments_crash() {
  echo "  Restoring: stop FIS experiment payments-crash..."

  local experiment_id
  experiment_id=$(ssm_get "/aiops-poc/chaos/payments-crash-experiment" "$MARKER_PROFILE")

  if [[ -z "$experiment_id" || "$experiment_id" == "None" ]]; then
    echo "  SKIP: No active payments-crash experiment recorded in SSM"
    return 0
  fi

  # Stop the experiment (idempotent — already-stopped experiments return success)
  $AWS fis stop-experiment --id "$experiment_id" > /dev/null 2>&1 || {
    echo "  INFO: Experiment $experiment_id may have already completed" >&2
  }

  echo "  FIS experiment stopped: $experiment_id"

  # Clean up SSM marker
  ssm_delete "/aiops-poc/chaos/payments-crash-experiment"
}

restore_db_overload() {
  echo "  Restoring: stop Aurora lock blocking simulation..."
  local url
  url=$(ssm_get "/petstore/petlistadoptionsurl")

  if [[ -z "$url" ]]; then
    echo "  SKIP: Could not resolve petlistadoptions URL (service may not be deployed)" >&2
    return 0
  fi

  # petlistadoptionsurl carries the /api/adoptionlist/ path — the simulator
  # endpoints live at the service root, so strip to origin.
  url=$(url_origin "$url")

  # Try the stop endpoint (some simulators have an explicit stop)
  curl -sf -X POST "$url/simulate/lockblocking/stop" -o /dev/null 2>/dev/null || true
  # Also try DELETE as an alternative stop mechanism
  curl -sf -X DELETE "$url/simulate/lockblocking" -o /dev/null 2>/dev/null || true

  echo "  Lock blocking simulation stop requested (may self-terminate on timeout)"
}

restore_ddb_throttle() {
  echo "  Restoring: return DynamoDB capacity to original values..."

  # Read saved values from SSM
  local original_rcu original_wcu table_name
  original_rcu=$(ssm_get "/aiops-poc/chaos/ddb-original-rcu" "$MARKER_PROFILE")
  original_wcu=$(ssm_get "/aiops-poc/chaos/ddb-original-wcu" "$MARKER_PROFILE")
  table_name=$(ssm_get "/aiops-poc/chaos/ddb-table-name" "$MARKER_PROFILE")

  if [[ -z "$original_rcu" || -z "$original_wcu" || -z "$table_name" ]]; then
    echo "  SKIP: No original DynamoDB capacity values found in SSM."
    echo "        (inject.sh may not have run, or values already cleared)"
    return 0
  fi

  echo "  Restoring $table_name: RCU=$original_rcu, WCU=$original_wcu"

  $AWS dynamodb update-table --table-name "$table_name" \
    --provisioned-throughput "ReadCapacityUnits=$original_rcu,WriteCapacityUnits=$original_wcu" > /dev/null

  echo "  Capacity restored"

  # Clean up SSM markers
  ssm_delete "/aiops-poc/chaos/ddb-original-rcu"
  ssm_delete "/aiops-poc/chaos/ddb-original-wcu"
  ssm_delete "/aiops-poc/chaos/ddb-table-name"
}

restore_status_consumer_off() {
  echo "  Restoring: re-enable the status-update queue's SQS event source mapping..."

  local uuid
  uuid=$(ssm_get "/aiops-poc/chaos/status-updater-esm-uuid" "$MARKER_PROFILE")

  if [[ -z "$uuid" || "$uuid" == "None" ]]; then
    # No saved UUID — resolve directly via the status-update queue ARN
    # (robust to the consumer function's deployment-generated name).
    local queue_url queue_arn
    queue_url=$(ssm_get "/petstore/queueurl")
    if [[ -n "$queue_url" ]]; then
      queue_arn=$($AWS sqs get-queue-attributes --queue-url "$queue_url" \
        --attribute-names QueueArn --query "Attributes.QueueArn" --output text 2>/dev/null || echo "")
      if [[ -n "$queue_arn" ]]; then
        uuid=$($AWS lambda list-event-source-mappings \
          --event-source-arn "$queue_arn" \
          --query "EventSourceMappings[0].UUID" --output text 2>/dev/null || echo "")
      fi
    fi
  fi

  if [[ -z "$uuid" || "$uuid" == "None" ]]; then
    echo "  SKIP: Could not find event source mapping UUID (may not be deployed)"
    return 0
  fi

  # Re-enable (idempotent — enabling an already-enabled mapping is a no-op)
  $AWS lambda update-event-source-mapping --uuid "$uuid" --enabled > /dev/null

  echo "  Event source mapping re-enabled: $uuid"

  ssm_delete "/aiops-poc/chaos/status-updater-esm-uuid"
}

restore_search_crash() {
  echo "  Restoring: stop FIS experiment search-crash..."

  local experiment_id
  experiment_id=$(ssm_get "/aiops-poc/chaos/search-crash-experiment" "$MARKER_PROFILE")

  if [[ -z "$experiment_id" || "$experiment_id" == "None" ]]; then
    echo "  SKIP: No active search-crash experiment recorded in SSM"
    return 0
  fi

  $AWS fis stop-experiment --id "$experiment_id" > /dev/null 2>&1 || {
    echo "  INFO: Experiment $experiment_id may have already completed" >&2
  }

  echo "  FIS experiment stopped: $experiment_id"

  ssm_delete "/aiops-poc/chaos/search-crash-experiment"
}

restore_ui_no_scale() {
  echo "  Restoring: return petsite autoscaling MaxCapacity to original value..."

  local original_max
  original_max=$(ssm_get "/aiops-poc/chaos/ui-original-max-capacity" "$MARKER_PROFILE")

  if [[ -z "$original_max" || "$original_max" == "None" ]]; then
    echo "  SKIP: No original MaxCapacity found in SSM."
    echo "        (inject.sh may not have run, or value already cleared)"
    return 0
  fi

  # Resolve petsite ECS cluster/service names from SSM (FE account),
  # falling back to discovery — sets FE_CLUSTER / FE_SERVICE.
  resolve_fe_ecs
  local cluster_name="$FE_CLUSTER"
  local service_name="$FE_SERVICE"
  local resource_id="service/${cluster_name}/${service_name}"

  $AWS application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id "$resource_id" \
    --scalable-dimension "ecs:service:DesiredCount" \
    --max-capacity "$original_max" > /dev/null

  echo "  MaxCapacity restored to $original_max"

  ssm_delete "/aiops-poc/chaos/ui-original-max-capacity"
}

# --- Execute the restoration ---
case "$FAULT_ID" in
  checkout-degraded)   restore_checkout_degraded ;;
  payments-error)      restore_payments_error ;;
  payments-crash)      restore_payments_crash ;;
  db-overload)         restore_db_overload ;;
  ddb-throttle)        restore_ddb_throttle ;;
  status-consumer-off) restore_status_consumer_off ;;
  search-crash)        restore_search_crash ;;
  ui-no-scale)         restore_ui_no_scale ;;
esac

# --- Clear the active scenario marker ---
# Check if current active matches what we're restoring (or clear anyway for idempotency)
ACTIVE_SCENARIO=$($MARKER_AWS ssm get-parameter \
  --name "/aiops-poc/active-scenario" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "none")

if [[ "$ACTIVE_SCENARIO" == "$FAULT_ID" ]]; then
  $MARKER_AWS ssm put-parameter \
    --name "/aiops-poc/active-scenario" \
    --value "none" \
    --type String --overwrite > /dev/null
  echo ""
  echo "  Active scenario marker cleared."
elif [[ "$ACTIVE_SCENARIO" == "none" || -z "$ACTIVE_SCENARIO" ]]; then
  echo ""
  echo "  No active scenario marker was set (already clean)."
else
  echo ""
  echo "  NOTE: Active scenario is '$ACTIVE_SCENARIO', not '$FAULT_ID'."
  echo "        Marker left unchanged. Clear manually if needed."
fi

echo ""
echo "=== Fault '$FAULT_ID' restored successfully ==="
