#!/usr/bin/env bash
# loadgen/run.sh — Burst traffic generator for petsite shopper journey
# Drives additional load against the FE petsite to make injected faults
# breach their business SLOs during demos.
#
# Compliance: sends legitimate shopper-journey traffic our own application is
# expected to handle, which the Amazon EC2 Testing Policy
# (https://aws.amazon.com/ec2/testing/) permits without approval. MAX_RATE
# below is a hard ceiling so this script can never be repurposed for flooding
# (prohibited by https://aws.amazon.com/security/penetration-testing/).
# See chaos/README.md § "Compliance & AWS testing policies".
#
# Requirements: 14.1, 14.2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Sourced for the SSM lookup's --profile and --region defaults (task 11.4).
# This script sits outside the Deployment_Script set: it makes one optional SSM
# read and needs no other Replicator_Input, so the resolver is consulted
# lazily, in resolve_url, and a missing config file leaves the previous
# behaviour untouched.
source "${REPO_ROOT}/scripts/lib/config.sh"

# ─── Defaults ─────────────────────────────────────────────────────────────────
RATE=10            # requests per second
RATE_EXPLICIT=false # true once --rate is passed (so a path set can pick a default)
MAX_RATE=200       # hard ceiling (req/s) — compliance guard, do not raise casually
DURATION=60        # seconds
URL=""             # petsite base URL (resolved from arg, env, or SSM)
PROFILE=""         # AWS CLI profile for the SSM lookup (default: frontend.profile)
REGION=""          # AWS region for the SSM lookup, from frontend.region
                   # (override with AIOPS_FRONTEND_REGION; never left to the
                   # ambient environment — an unset region is what made this
                   # lookup fail in non-interactive shells)
TOOL=""            # hey or curl (auto-detected)
VERBOSE=false
PATHSET="journey"  # journey (default, 4 routes) | search (search routes only)
SEARCH_DEFAULT_RATE=12  # known-good B4 driver rate (see docs/deployment.md B4 run-log)

# ─── Signal handling ──────────────────────────────────────────────────────────
RUNNING=true
cleanup() {
  RUNNING=false
  echo ""
  echo "=== Burst stopped (signal received) ==="
  print_summary
  exit 0
}
trap cleanup SIGINT SIGTERM

# ─── Counters ─────────────────────────────────────────────────────────────────
TOTAL_REQUESTS=0
SUCCESSFUL=0
FAILED=0
START_TIME=""

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Burst traffic generator — shopper journey against petsite.

Options:
  --rate <n>         Requests per second (default: 10, or ${SEARCH_DEFAULT_RATE} with --paths search)
  --duration <n>     Duration in seconds (default: 60)
  --paths <set>      Route set: journey (default) | search
  --url <url>        Petsite base URL (default: from PETSITE_URL env or SSM)
  --profile <name>   AWS CLI profile for the SSM lookup
                     (default: config/accounts.json → frontend.profile;
                      the region comes from frontend.region and is always
                      passed to the CLI explicitly, so the lookup works in a
                      non-interactive shell with no region in the environment)
  --verbose          Print each request result
  -h, --help         Show this help

Route sets:
  journey  Full shopper journey — homepage, /PetListAdoptions (full + filtered),
           /FoodService. Broad fan-out; drives petsite CPU hard.
  search   Search only — homepage '/?userId=…' plus two filtered searches
           '/?userId=…&selectedPetType=…&selectedPetColor=…'. Deliberately
           EXCLUDES /PetListAdoptions and /FoodService, and defaults to a low
           ${SEARCH_DEFAULT_RATE} req/s. This is the dependency-starvation driver
           (B4 ddb-throttle): enough read pressure to demand ~8-12 RCU/s from the
           adoptions DynamoDB table while leaving petsite and petsearch-java idle,
           so the fault is attributable. High rates (--rate 30/50) saturate petsite
           and OOM-kill the web container (exit 137, 1024 MiB) BEFORE DynamoDB ever
           throttles — see docs/deployment.md, B4 run-logs.

Examples:
  ./run.sh --rate 50 --duration 120
  ./run.sh --paths search --duration 1500              # B4 driver, ~12 req/s
  ./run.sh --url https://d111111abcdef8.cloudfront.net --rate 30 --duration 60
  PETSITE_URL=https://... ./run.sh --rate 20 --duration 300
  ./run.sh --rate 50 --duration 180

EOF
  exit 0
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rate)      RATE="$2"; RATE_EXPLICIT=true; shift 2 ;;
    --duration)  DURATION="$2"; shift 2 ;;
    --paths)     PATHSET="$2"; shift 2 ;;
    --url)       URL="$2"; shift 2 ;;
    --profile)   PROFILE="$2"; shift 2 ;;
    --verbose)   VERBOSE=true; shift ;;
    -h|--help)   usage ;;
    *)           echo "Unknown option: $1"; usage ;;
  esac
done

# ─── Path-set validation + rate default ───────────────────────────────────────
case "$PATHSET" in
  journey) ;;
  search)
    # Search-only load is a low-rate driver by design; only override the default
    # when the operator explicitly asked for a rate.
    [[ "$RATE_EXPLICIT" == false ]] && RATE="$SEARCH_DEFAULT_RATE"
    ;;
  *)
    echo "ERROR: --paths must be 'journey' or 'search' (got: $PATHSET)" >&2
    exit 1
    ;;
esac

# ─── Rate guard (compliance ceiling) ──────────────────────────────────────────
if ! [[ "$RATE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --rate must be a positive integer (got: $RATE)" >&2
  exit 1
fi
if [[ "$RATE" -gt "$MAX_RATE" ]]; then
  echo "ERROR: --rate $RATE exceeds the MAX_RATE ceiling of ${MAX_RATE} req/s." >&2
  echo "  This ceiling keeps the generator within AWS testing policies —" >&2
  echo "  request flooding is prohibited. See chaos/README.md" >&2
  echo "  § 'Compliance & AWS testing policies' before considering a change." >&2
  exit 1
fi

# ─── FE inputs for the SSM lookup ─────────────────────────────────────────────
PETSITE_URL_PARAM="/aiops-poc/workload/petsite-url"

FE_PROFILE_DEFAULT=""
FE_PROFILE_ORIGIN=""
FE_REGION_DEFAULT=""
FE_REGION_ORIGIN=""

# Fill FE_{PROFILE,REGION}_{DEFAULT,ORIGIN} from the shared Config_Resolver in
# one subshell. config::init is fatal by design (no jq, no config/accounts.json)
# and this script's SSM read is optional, so the resolver is fenced off here: a
# failure leaves the fields empty, which keeps the pre-refactor behaviour of
# calling aws with whatever is ambient — but now the failure message names what
# could not be resolved.
# Bash 3.2 has no associative arrays, so the resolver's output lines are written
# into their four variable names with printf -v and read back by indirect
# expansion.
resolve_fe_defaults() {
  local resolved var lineno=1
  resolved="$( ( config::init \
                   && config::get frontend.profile \
                   && config::origin frontend.profile \
                   && config::get frontend.region \
                   && config::origin frontend.region ) 2>/dev/null || true )"
  for var in FE_PROFILE_DEFAULT FE_PROFILE_ORIGIN FE_REGION_DEFAULT FE_REGION_ORIGIN; do
    printf -v "$var" '%s' "$(printf '%s\n' "$resolved" | sed -n "${lineno}p")"
    lineno=$((lineno + 1))
  done
  printf -v FE_PROFILE_ORIGIN '%s' \
    "frontend.profile — ${FE_PROFILE_ORIGIN:-not resolved from config/accounts.json}"
  printf -v FE_REGION_ORIGIN '%s' \
    "frontend.region — ${FE_REGION_ORIGIN:-not resolved from config/accounts.json}"
}

# ─── Resolve petsite URL ──────────────────────────────────────────────────────
resolve_url() {
  # Priority: --url arg > PETSITE_URL env > SSM parameter
  if [[ -n "$URL" ]]; then
    echo "$URL"
    return
  fi

  if [[ -n "${PETSITE_URL:-}" ]]; then
    echo "$PETSITE_URL"
    return
  fi

  # Try SSM. The parameter lives in the FE account (petsite is an FE workload),
  # so an absent --profile falls back to the configured frontend profile and the
  # region to the configured frontend region — both passed to the CLI
  # explicitly, per the workspace AWS deployment rules. Relying on an ambient
  # region is what broke this call in a non-interactive shell, which is exactly
  # the shell a replicator (or an agent) runs it from.
  echo "Resolving petsite URL from SSM ${PETSITE_URL_PARAM} ..." >&2
  resolve_fe_defaults
  if [[ -n "$PROFILE" ]]; then
    FE_PROFILE_ORIGIN="--profile flag"
  else
    PROFILE="$FE_PROFILE_DEFAULT"
  fi
  REGION="$FE_REGION_DEFAULT"

  local aws_args=( ssm get-parameter --name "$PETSITE_URL_PARAM" --query "Parameter.Value" --output text )
  if [[ -n "$PROFILE" ]]; then
    aws_args+=( --profile "$PROFILE" )
  fi
  if [[ -n "$REGION" ]]; then
    aws_args+=( --region "$REGION" )
  fi

  local ssm_url err_file ssm_err
  err_file="$(mktemp 2>/dev/null || echo "/tmp/loadgen_ssm_err.$$")"
  if ssm_url=$(aws "${aws_args[@]}" 2>"$err_file"); then
    rm -f "$err_file"
    echo "$ssm_url"
    return
  fi
  ssm_err="$(head -3 "$err_file" 2>/dev/null || true)"
  rm -f "$err_file"

  echo "ERROR: Cannot resolve the petsite URL from SSM." >&2
  echo "  Parameter: ${PETSITE_URL_PARAM}" >&2
  echo "  Profile:   ${PROFILE:-(none)}  (${FE_PROFILE_ORIGIN})" >&2
  echo "  Region:    ${REGION:-(none)}  (${FE_REGION_ORIGIN})" >&2
  if [[ -n "$ssm_err" ]]; then
    echo "  The AWS CLI reported:" >&2
    printf '%s\n' "$ssm_err" | sed 's/^/    /' >&2
  fi
  echo "  Options:" >&2
  echo "    - Skip the lookup entirely:  --url https://<petsite-cloudfront-domain>" >&2
  echo "      (or export PETSITE_URL=https://<petsite-cloudfront-domain>)" >&2
  echo "    - Refresh credentials:       e.g. aws sso login --profile ${PROFILE:-<fe-profile>}" >&2
  echo "    - Check the parameter:       aws ssm get-parameter --name ${PETSITE_URL_PARAM}" \
       "--profile ${PROFILE:-<fe-profile>} --region ${REGION:-<fe-region>}" >&2
  echo "    - Override profile/region:   --profile <name>, or export AIOPS_FRONTEND_REGION=<region>" >&2
  echo "      (defaults come from config/accounts.json → frontend.profile / frontend.region)" >&2
  exit 1
}

# ─── Tool detection ───────────────────────────────────────────────────────────
detect_tool() {
  if command -v hey &>/dev/null; then
    TOOL="hey"
  elif command -v curl &>/dev/null; then
    TOOL="curl"
  else
    echo "ERROR: Neither 'hey' nor 'curl' found in PATH." >&2
    echo "  Install hey: go install github.com/rakyll/hey@v0.1.5" >&2
    exit 1
  fi
}

# ─── Random data generators ──────────────────────────────────────────────────
# Real petsite filter values (discovered from the live search form:
# selectedPetType / selectedPetColor options on the homepage).
PET_TYPES=("all" "puppy" "kitten" "bunny")
PET_COLORS=("all" "brown" "black" "white")

random_pet_type() {
  echo "${PET_TYPES[$((RANDOM % ${#PET_TYPES[@]}))]}"
}

random_pet_color() {
  echo "${PET_COLORS[$((RANDOM % ${#PET_COLORS[@]}))]}"
}

# Extract the shopper userId that petsite assigns on the homepage 302 redirect
# (Location: /?userId=userNNNNN). The list/search/food pages need this query
# param to return 200 (otherwise petsite 302s to assign a new session).
random_user_id() {
  echo "user$((RANDOM % 90000 + 10000))"
}

# ─── Request functions (curl mode) ───────────────────────────────────────────
do_request_curl() {
  local url="$1"
  local method="${2:-GET}"
  local data="${3:-}"

  local http_code
  local args=( -s -o /dev/null -w "%{http_code}" --max-time 10 )

  if [[ "$method" == "POST" ]]; then
    args+=( -X POST -H "Content-Type: application/x-www-form-urlencoded" )
    if [[ -n "$data" ]]; then
      args+=( -d "$data" )
    fi
  fi

  http_code=$(curl "${args[@]}" "$url" 2>/dev/null || echo "000")
  # Trim to first 3 characters (the HTTP status code)
  http_code="${http_code:0:3}"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))

  if [[ "$http_code" =~ ^[23] ]]; then
    SUCCESSFUL=$((SUCCESSFUL + 1))
    [[ "$VERBOSE" == true ]] && echo "  [OK]  $method $url -> $http_code"
  else
    FAILED=$((FAILED + 1))
    [[ "$VERBOSE" == true ]] && echo "  [ERR] $method $url -> $http_code"
  fi
}

# ─── Shopper journey (one iteration) ─────────────────────────────────────────
# Routes discovered live from the deployed petsite (.NET/Kestrel). All four
# steps are idempotent GETs that fan out to the backend adoption/search
# services, driving real CPU + dependency load without mutating inventory.
run_journey_curl() {
  local base="$1"
  local hdr uid code ptype pcolor

  # Step 1: Browse homepage — capture the userId petsite assigns via 302.
  hdr=$(mktemp 2>/dev/null || echo "/tmp/loadgen_hdr.$$")
  code=$(curl -sS -D "$hdr" -o /dev/null -w "%{http_code}" --max-time 10 "${base}/" 2>/dev/null || echo "000")
  code="${code:0:3}"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
  if [[ "$code" =~ ^[23] ]]; then
    SUCCESSFUL=$((SUCCESSFUL + 1))
    [[ "$VERBOSE" == true ]] && echo "  [OK]  GET ${base}/ -> $code"
  else
    FAILED=$((FAILED + 1))
    [[ "$VERBOSE" == true ]] && echo "  [ERR] GET ${base}/ -> $code"
  fi
  uid=$(grep -io 'userId=user[0-9]*' "$hdr" 2>/dev/null | head -1 | cut -d= -f2)
  rm -f "$hdr"
  [[ -z "$uid" ]] && uid="$(random_user_id)"

  ptype="$(random_pet_type)"
  pcolor="$(random_pet_color)"

  # Step 2: Browse the full adoption list (fans out to backend petsearch).
  do_request_curl "${base}/PetListAdoptions?userId=${uid}"

  # Step 3: Filtered search (fans out to backend search with type/color).
  do_request_curl "${base}/PetListAdoptions?userId=${uid}&selectedPetType=${ptype}&selectedPetColor=${pcolor}"

  # Step 4: View the pet food service page (additional render + dependency).
  do_request_curl "${base}/FoodService?userId=${uid}&petType=${ptype}"
}

# ─── Search-only iteration (--paths search) ──────────────────────────────────
# Three requests: the homepage search view plus two filtered searches. These are
# the only petsite routes that reach petsearch-java → the adoptions DynamoDB
# table, so read pressure lands on the dependency instead of on petsite's
# renderer. /PetListAdoptions and /FoodService are excluded on purpose.
run_search_curl() {
  local base="$1"
  local hdr uid code

  hdr=$(mktemp 2>/dev/null || echo "/tmp/loadgen_hdr.$$")
  code=$(curl -sS -D "$hdr" -o /dev/null -w "%{http_code}" --max-time 35 "${base}/" 2>/dev/null || echo "000")
  code="${code:0:3}"
  TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
  if [[ "$code" =~ ^[23] ]]; then
    SUCCESSFUL=$((SUCCESSFUL + 1))
    [[ "$VERBOSE" == true ]] && echo "  [OK]  GET ${base}/ -> $code"
  else
    FAILED=$((FAILED + 1))
    [[ "$VERBOSE" == true ]] && echo "  [ERR] GET ${base}/ -> $code"
  fi
  uid=$(grep -io 'userId=user[0-9]*' "$hdr" 2>/dev/null | head -1 | cut -d= -f2)
  rm -f "$hdr"
  [[ -z "$uid" ]] && uid="$(random_user_id)"

  do_request_curl "${base}/?userId=${uid}&selectedPetType=$(random_pet_type)&selectedPetColor=$(random_pet_color)"
  do_request_curl "${base}/?userId=${uid}&selectedPetType=$(random_pet_type)&selectedPetColor=$(random_pet_color)"
}

# ─── hey-based burst ─────────────────────────────────────────────────────────
run_hey_burst() {
  local base="$1"
  local total_requests=$((RATE * DURATION))
  local per_endpoint=$((total_requests / 4))

  echo "Running hey burst: ${total_requests} total requests across 4 endpoints"
  echo ""

  # Capture a userId from the homepage 302 so the list/search/food routes
  # return 200 (they 302 without a session userId).
  local hdr uid ptype pcolor
  hdr=$(mktemp 2>/dev/null || echo "/tmp/loadgen_hdr.$$")
  curl -sS -D "$hdr" -o /dev/null --max-time 10 "${base}/" 2>/dev/null || true
  uid=$(grep -io 'userId=user[0-9]*' "$hdr" 2>/dev/null | head -1 | cut -d= -f2)
  rm -f "$hdr"
  [[ -z "$uid" ]] && uid="$(random_user_id)"
  ptype="$(random_pet_type)"
  pcolor="$(random_pet_color)"
  echo "  (carrying userId=${uid}, petType=${ptype}, petColor=${pcolor})"

  # hey distributes requests evenly across duration
  # Run each endpoint in parallel
  local pids=()

  echo "  [1/4] GET / (homepage) — ${per_endpoint} requests at $((RATE/4))/s"
  hey -n "$per_endpoint" -q "$((RATE/4))" -z "${DURATION}s" -t 10 "${base}/" > /tmp/loadgen_hey_home.txt 2>&1 &
  pids+=($!)

  echo "  [2/4] GET /PetListAdoptions (adoption list) — ${per_endpoint} requests at $((RATE/4))/s"
  hey -n "$per_endpoint" -q "$((RATE/4))" -z "${DURATION}s" -t 10 "${base}/PetListAdoptions?userId=${uid}" > /tmp/loadgen_hey_list.txt 2>&1 &
  pids+=($!)

  echo "  [3/4] GET /PetListAdoptions (filtered search) — ${per_endpoint} requests at $((RATE/4))/s"
  hey -n "$per_endpoint" -q "$((RATE/4))" -z "${DURATION}s" -t 10 "${base}/PetListAdoptions?userId=${uid}&selectedPetType=${ptype}&selectedPetColor=${pcolor}" > /tmp/loadgen_hey_search.txt 2>&1 &
  pids+=($!)

  echo "  [4/4] GET /FoodService (food service) — ${per_endpoint} requests at $((RATE/4))/s"
  hey -n "$per_endpoint" -q "$((RATE/4))" -z "${DURATION}s" -t 10 "${base}/FoodService?userId=${uid}&petType=${ptype}" > /tmp/loadgen_hey_food.txt 2>&1 &
  pids+=($!)

  echo ""
  echo "Burst running for ${DURATION}s ... (Ctrl+C to stop)"

  # Wait for all hey processes
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  echo ""
  echo "=== hey burst results ==="
  echo ""

  # Aggregate status codes across all four endpoints so the summary clearly
  # shows the 2xx/3xx vs 4xx/5xx split (a 404 here means a broken journey route).
  local agg_total=0 agg_ok=0 agg_bad=0
  for label_file in "Homepage:/tmp/loadgen_hey_home.txt" "Adoption list:/tmp/loadgen_hey_list.txt" "Filtered search:/tmp/loadgen_hey_search.txt" "Food service:/tmp/loadgen_hey_food.txt"; do
    local label="${label_file%%:*}"
    local file="${label_file##*:}"
    echo "--- $label ---"
    if [[ -s "$file" ]]; then
      # Timing + requests/sec summary from hey.
      grep -E "^(Summary|  Total:|  Slowest:|  Fastest:|  Average:|  Requests/sec:)" "$file" 2>/dev/null || true
      # Status code distribution header + per-code count lines ("  [200]\tN responses").
      grep -E "^Status code distribution:|^[[:space:]]+\[[0-9]{3}\]" "$file" 2>/dev/null || echo "  (no status codes reported)"
      # Tally this endpoint's codes into the aggregate.
      while read -r code count; do
        [[ -z "$code" ]] && continue
        agg_total=$((agg_total + count))
        if [[ "$code" =~ ^[23] ]]; then
          agg_ok=$((agg_ok + count))
        else
          agg_bad=$((agg_bad + count))
        fi
      done < <(grep -oE '\[[0-9]{3}\][[:space:]]+[0-9]+' "$file" 2>/dev/null \
                 | sed -E 's/\[([0-9]{3})\][[:space:]]+([0-9]+)/\1 \2/')
    else
      echo "  (no output captured for this endpoint)"
    fi
    echo ""
  done

  echo "=== Burst Summary (all endpoints) ==="
  echo "  Total:        ${agg_total} responses"
  echo "  Successful:   ${agg_ok} (2xx/3xx)"
  echo "  Failed:       ${agg_bad} (4xx/5xx)"
  if [[ "$agg_total" -gt 0 ]]; then
    local ok_pct=$((agg_ok * 100 / agg_total))
    echo "  Success rate: ${ok_pct}%"
  fi
  echo ""

  # Cleanup temp files
  rm -f /tmp/loadgen_hey_home.txt /tmp/loadgen_hey_list.txt \
        /tmp/loadgen_hey_search.txt /tmp/loadgen_hey_food.txt
}

# ─── hey-based search-only burst (--paths search) ────────────────────────────
# Three workers, each rate-limited, against the three search routes only. The
# known-good B4 recipe is 3 × (-c 2 -q 2) = ~12 req/s total.
run_hey_search_burst() {
  local base="$1"
  local per_proc=$((RATE / 3))
  [[ "$per_proc" -lt 1 ]] && per_proc=1
  local conc=2
  local qps=$((per_proc / conc))
  [[ "$qps" -lt 1 ]] && { qps=1; conc=$per_proc; }
  [[ "$conc" -lt 1 ]] && conc=1

  local hdr uid
  hdr=$(mktemp 2>/dev/null || echo "/tmp/loadgen_hdr.$$")
  curl -sS -D "$hdr" -o /dev/null --max-time 35 "${base}/" 2>/dev/null || true
  uid=$(grep -io 'userId=user[0-9]*' "$hdr" 2>/dev/null | head -1 | cut -d= -f2)
  rm -f "$hdr"
  [[ -z "$uid" ]] && uid="$(random_user_id)"

  local t1 c1 t2 c2
  t1="$(random_pet_type)"; c1="$(random_pet_color)"
  t2="$(random_pet_type)"; c2="$(random_pet_color)"

  echo "Running hey SEARCH-ONLY load: 3 workers × (-c ${conc} -q ${qps}) ≈ $((3 * conc * qps)) req/s for ${DURATION}s"
  echo "  (carrying userId=${uid}; routes: / and two filtered searches; no /PetListAdoptions, no /FoodService)"
  echo ""

  local urls=(
    "${base}/?userId=${uid}"
    "${base}/?userId=${uid}&selectedPetType=${t1}&selectedPetColor=${c1}"
    "${base}/?userId=${uid}&selectedPetType=${t2}&selectedPetColor=${c2}"
  )
  local files=(/tmp/loadgen_hey_s1.txt /tmp/loadgen_hey_s2.txt /tmp/loadgen_hey_s3.txt)
  local pids=() i
  for i in 0 1 2; do
    echo "  [$((i + 1))/3] GET ${urls[$i]}"
    hey -c "$conc" -q "$qps" -z "${DURATION}s" -t 35 "${urls[$i]}" > "${files[$i]}" 2>&1 &
    pids+=($!)
  done

  echo ""
  echo "Search load running for ${DURATION}s ... (Ctrl+C to stop)"
  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  echo ""
  echo "=== hey search-only results ==="
  local agg_total=0 agg_ok=0 agg_bad=0
  for i in 0 1 2; do
    echo "--- worker $((i + 1)) ---"
    if [[ -s "${files[$i]}" ]]; then
      grep -E "^(Summary|  Total:|  Slowest:|  Fastest:|  Average:|  Requests/sec:)" "${files[$i]}" 2>/dev/null || true
      grep -E "^Status code distribution:|^[[:space:]]+\[[0-9]{3}\]" "${files[$i]}" 2>/dev/null || echo "  (no status codes reported)"
      while read -r code count; do
        [[ -z "$code" ]] && continue
        agg_total=$((agg_total + count))
        if [[ "$code" =~ ^[23] ]]; then
          agg_ok=$((agg_ok + count))
        else
          agg_bad=$((agg_bad + count))
        fi
      done < <(grep -oE '\[[0-9]{3}\][[:space:]]+[0-9]+' "${files[$i]}" 2>/dev/null \
                 | sed -E 's/\[([0-9]{3})\][[:space:]]+([0-9]+)/\1 \2/')
    else
      echo "  (no output captured)"
    fi
    echo ""
  done

  echo "=== Search Load Summary ==="
  echo "  Total:        ${agg_total} responses"
  echo "  Successful:   ${agg_ok} (2xx/3xx)"
  echo "  Failed:       ${agg_bad} (4xx/5xx)"
  if [[ "$agg_total" -gt 0 ]]; then
    echo "  Success rate: $((agg_ok * 100 / agg_total))%"
  fi
  echo ""
  rm -f "${files[@]}"
}

# ─── curl-based burst loop ───────────────────────────────────────────────────
run_curl_burst() {
  local base="$1"
  local interval
  # requests per iteration: 4 for the full journey, 3 for search-only
  local per_iter=4
  [[ "$PATHSET" == "search" ]] && per_iter=3
  # rate is requests/sec, so wait per_iter/RATE seconds between iterations
  interval=$(awk "BEGIN {printf \"%.3f\", ${per_iter}.0/$RATE}")

  echo "Running curl burst (${PATHSET}): ~${RATE} req/s for ${DURATION}s (interval: ${interval}s per iteration)"
  echo ""

  local end_time=$(($(date +%s) + DURATION))
  local journey_count=0

  while [[ "$(date +%s)" -lt "$end_time" ]] && [[ "$RUNNING" == true ]]; do
    if [[ "$PATHSET" == "search" ]]; then
      run_search_curl "$base"
    else
      run_journey_curl "$base"
    fi
    journey_count=$((journey_count + 1))

    # Progress every 10 journeys
    if [[ $((journey_count % 10)) -eq 0 ]]; then
      local elapsed=$(( $(date +%s) - ${START_TIME%.*} ))
      local actual_rate=0
      if [[ $elapsed -gt 0 ]]; then
        actual_rate=$((TOTAL_REQUESTS / elapsed))
      fi
      echo "  Progress: ${journey_count} journeys, ${TOTAL_REQUESTS} requests, ~${actual_rate} req/s"
    fi

    # Sleep to maintain target rate
    sleep "$interval" 2>/dev/null || true
  done
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  if [[ "$TOOL" == "curl" ]]; then
    local end_ts
    end_ts=$(date +%s)
    local elapsed=$(( end_ts - ${START_TIME%.*} ))
    local actual_rate=0
    if [[ $elapsed -gt 0 ]]; then
      actual_rate=$((TOTAL_REQUESTS / elapsed))
    fi

    echo ""
    echo "=== Burst Summary ==="
    echo "  Duration:     ${elapsed}s"
    echo "  Total:        ${TOTAL_REQUESTS} requests"
    echo "  Successful:   ${SUCCESSFUL}"
    echo "  Failed:       ${FAILED}"
    echo "  Actual rate:  ~${actual_rate} req/s"
    if [[ $TOTAL_REQUESTS -gt 0 ]]; then
      local success_pct=$((SUCCESSFUL * 100 / TOTAL_REQUESTS))
      echo "  Success rate: ${success_pct}%"
    fi
    echo ""
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  echo "=== loadgen burst generator ==="
  echo ""

  URL=$(resolve_url)
  # Strip trailing slash
  URL="${URL%/}"
  echo "Target:   $URL"
  echo "Rate:     ${RATE} req/s"
  echo "Duration: ${DURATION}s"
  echo "Paths:    ${PATHSET}"

  detect_tool
  echo "Tool:     $TOOL"
  echo ""

  START_TIME=$(date +%s)

  if [[ "$TOOL" == "hey" ]]; then
    if [[ "$PATHSET" == "search" ]]; then
      run_hey_search_burst "$URL"
    else
      run_hey_burst "$URL"
    fi
  else
    run_curl_burst "$URL"
    print_summary
  fi

  echo "Done."
}

main
