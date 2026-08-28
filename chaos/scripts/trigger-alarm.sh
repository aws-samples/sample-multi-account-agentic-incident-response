#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# chaos/scripts/trigger-alarm.sh — Force a business SLO alarm into ALARM
#
# Emergency demo lever: fires the incident chain WITHOUT injecting a real
# fault, using the documented CloudWatch testing API `set-alarm-state`.
# The forced OK→ALARM transition fires the alarm's SNS action → webhook
# bridge → app-team first-responder investigation.
#
# IMPORTANT — transient by design:
#   * CloudWatch re-evaluates the alarm on its next evaluation period and
#     flips it back to OK automatically. No restore step is needed.
#   * No real fault is injected, so the triggered investigation will find
#     no genuine fault evidence. This lever demonstrates the TRIGGER FLOW
#     only. For realistic investigations use ./chaos/scripts/inject.sh.
#   * Because no fault is active, this script does NOT record
#     /aiops-poc/active-scenario.
#
# Usage:
#   ./chaos/scripts/trigger-alarm.sh [<alarm-name>] [--list] [--profile <name>] [--region <region>]
#
#   --list (or no alarm-name)  Enumerate candidate business SLO alarms in
#                              both workload accounts (BE + FE).
#   <alarm-name>               Force that alarm into ALARM state. The owning
#                              account is auto-detected (BE first, then FE)
#                              unless --profile is given explicitly.
#
# WHICH ALARMS ARE CANDIDATES (three-tier design, alarm name encodes origin):
#   * aiops-poc-fe-golden-journey-success
#   * aiops-poc-fe-golden-journey-duration
#   * aiops-poc-fe-golden-checkout-error-rate   (FE, all three PAGE)
#   * aiops-poc-be-slo-statusupdate-lag         (BE, PAGES — B2 is async, so
#                                                the FE canary journey cannot
#                                                see it)
#   ...and that is the complete list. Only those four alarms have SNS alarm
#   actions, and `--list` filters on exactly that (AlarmActions containing an
#   SNS incidents topic), so nothing else shows up.
#
#   The other five aiops-poc-be-slo-* alarms (checkout-latency-p99,
#   payments-error-rate, payments-availability, search-latency-p99,
#   search-error-rate) and all six aiops-poc-be-infra-* alarms are
#   deliberately ACTIONLESS — they are EVIDENCE for an investigation, not
#   triggers. Their absence from `--list` is intended, not a bug or a missing
#   deploy: forcing them into ALARM would fire nothing. Trigger the FE golden
#   signal instead (that is the customer-facing symptom the incident should be
#   framed around).
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# The target region and both workload profiles come from the Config_Resolver —
# the one shared location that reads config/accounts.json (Requirements 2.3,
# 2.6). They are resolved after argument parsing, below, so that --profile and
# --region sit at the top of the precedence chain.
source "$REPO_ROOT/scripts/lib/config.sh"

# Alarms are created by BackendOverlayStack (BE) and FrontendStack (FE) with
# the "aiops-poc-" name prefix, and the PAGING ones action the account's
# incidents SNS topic (aiops-poc-incidents / aiops-poc-fe-incidents). Both
# facts are used to filter reliably — which is why the evidence-only BE SLO
# and BE infra alarms are (intentionally) not listed. See the header note.
ALARM_PREFIX="aiops-poc"

LIST_ONLY=false
PROFILE_FLAG=""
REGION_FLAG=""
ALARM_NAME=""

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=true
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
      echo "Usage: $0 [<alarm-name>] [--list] [--profile <name>] [--region <region>]"
      echo ""
      echo "Without an alarm-name (or with --list): lists candidate business SLO"
      echo "alarms in both workload accounts (BE + FE)."
      echo ""
      echo "With an alarm-name: forces that alarm into ALARM via"
      echo "'aws cloudwatch set-alarm-state'. The alarm auto-reverts to OK on"
      echo "the next evaluation period — no restore needed. NOTE: no real fault"
      echo "is injected, so the investigation will find nothing broken; this"
      echo "demonstrates the trigger flow only (use inject.sh for realism)."
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$ALARM_NAME" ]]; then
        ALARM_NAME="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# --- Resolve region and profiles (flag > env > config file > template) ---
config::init
config::resolve ops.region "$REGION_FLAG"
DEFAULT_REGION="$(config::get ops.region)"
BE_PROFILE="$(config::get backend.profile)"
FE_PROFILE="$(config::get frontend.profile)"

TARGET_REGION="${REGION_FLAG:-$DEFAULT_REGION}"

# --- Helper: map an alarm name to the incident it drives (B1–B5) ---
# Patterns match the three-tier alarm names (see docs/scenarios.md):
#   aiops-poc-fe-golden-*  customer-facing golden signals (FE, all page)
#   aiops-poc-be-slo-*     per-service business SLOs (BE, evidence only
#                          except -statusupdate-lag)
#   aiops-poc-be-infra-*   infra evidence (BE, never pages) → "?"
#
# ORDERING MATTERS: *checkout-error-rate* (the FE golden view of payments
# failing → B3) must be tested BEFORE *checkout-latency* (B1) so the two
# cannot shadow each other.
incident_for_alarm() {
  case "$1" in
    # FE golden: petsite 5xx rate — the customer-facing view of payments
    # failing, so it drives the same incident as the BE payments SLOs.
    *checkout-error-rate*)   echo "B3" ;;
    *checkout-latency*)      echo "B1" ;;
    *statusupdate-lag*)      echo "B2" ;;
    *payments-error*|*payments-availability*) echo "B3" ;;
    *search-latency*|*search-error*) echo "B4" ;;
    *journey*)               echo "B5" ;;
    *)                       echo "?"  ;;
  esac
}

# --- Helper: list business SLO alarms for one profile ---
# Filters: name prefix "aiops-poc" AND at least one alarm action pointing at
# an SNS incidents topic (excludes autoscaling TargetTracking alarms etc.).
list_alarms_for_profile() {
  local profile="$1"
  local account_label="$2"
  aws --profile "$profile" --region "$TARGET_REGION" cloudwatch describe-alarms \
    --alarm-name-prefix "$ALARM_PREFIX" \
    --query "MetricAlarms[?AlarmActions[?contains(@, ':sns:') && contains(@, 'incidents')]].[AlarmName,StateValue]" \
    --output text 2>/dev/null | while IFS=$'\t' read -r name state; do
      [[ -z "$name" ]] && continue
      printf "%-40s %-4s %-8s %s\n" "$name" "$account_label" "$(incident_for_alarm "$name")" "$state"
    done
}

do_list() {
  echo "=== Paging alarms (candidates for trigger-alarm.sh) ==="
  echo "    Region: $TARGET_REGION"
  echo "    Only alarms with an SNS incidents action are listed: the 3 FE"
  echo "    golden signals + aiops-poc-be-slo-statusupdate-lag. The other BE"
  echo "    SLO alarms and all BE infra alarms are evidence-only (no action)"
  echo "    by design, so they are not triggerable."
  echo ""
  printf "%-40s %-4s %-8s %s\n" "ALARM NAME" "ACCT" "INCIDENT" "STATE"
  printf "%-40s %-4s %-8s %s\n" "----------" "----" "--------" "-----"
  list_alarms_for_profile "$BE_PROFILE" "BE"
  list_alarms_for_profile "$FE_PROFILE" "FE"
  echo ""
  echo "Trigger one with:  $0 <alarm-name>"
}

# --- Helper: does <alarm-name> exist under <profile>? ---
alarm_exists() {
  local profile="$1"
  local found
  found=$(aws --profile "$profile" --region "$TARGET_REGION" cloudwatch describe-alarms \
    --alarm-names "$ALARM_NAME" \
    --query "length(MetricAlarms)" --output text 2>/dev/null || echo "0")
  [[ "$found" == "1" ]]
}

do_trigger() {
  local target_profile account_label

  if [[ -n "$PROFILE_FLAG" ]]; then
    target_profile="$PROFILE_FLAG"
    account_label="(explicit --profile)"
    if ! alarm_exists "$target_profile"; then
      echo "ERROR: Alarm '$ALARM_NAME' not found under profile '$target_profile' in $TARGET_REGION." >&2
      exit 1
    fi
  elif alarm_exists "$BE_PROFILE"; then
    target_profile="$BE_PROFILE"
    account_label="BE"
  elif alarm_exists "$FE_PROFILE"; then
    target_profile="$FE_PROFILE"
    account_label="FE"
  else
    echo "ERROR: Alarm '$ALARM_NAME' not found in BE or FE account ($TARGET_REGION)." >&2
    echo "       Run '$0 --list' to see candidate alarms." >&2
    exit 1
  fi

  echo "=== Demo trigger: forcing '$ALARM_NAME' into ALARM ==="
  echo "    Account: $account_label | Profile: $target_profile | Region: $TARGET_REGION"
  echo "    Incident: $(incident_for_alarm "$ALARM_NAME")"
  echo ""

  aws --profile "$target_profile" --region "$TARGET_REGION" cloudwatch set-alarm-state \
    --alarm-name "$ALARM_NAME" \
    --state-value ALARM \
    --state-reason "Demo trigger: simulated business SLO breach (trigger-alarm.sh; no real fault injected)"

  echo "Alarm state set to ALARM."
  echo ""
  echo "What happens next:"
  echo "  (a) The OK→ALARM transition fires the SNS alarm action — the webhook"
  echo "      bridge should invoke the first responder within seconds."
  echo "  (b) The alarm auto-reverts to OK on its next evaluation period —"
  echo "      this trigger is transient by design; no restore step is needed."
  echo "  (c) No real fault was injected, so the investigation will find no"
  echo "      genuine fault evidence. This lever demonstrates the TRIGGER FLOW"
  echo "      only — for realistic investigations use:"
  echo "        ./chaos/scripts/inject.sh <fault-id> --confirm"
}

if [[ "$LIST_ONLY" == "true" || -z "$ALARM_NAME" ]]; then
  do_list
else
  do_trigger
fi
