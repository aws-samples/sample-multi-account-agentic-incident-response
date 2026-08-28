#!/usr/bin/env bash
#
# capture-baseline.sh — record the observable surface of this repository so that
# a refactor can be proven not to have changed it.
#
# Captures three things from a source tree:
#   1. Synthesized CloudFormation templates for the four CDK apps
#   2. Per-suite test pass/fail counts (jest and pytest)
#   3. Every SSM parameter name and CloudFormation export name
#
# Used by the centralized-parameters spec: task 1 captures the "before" side
# against a pristine worktree, task 17 captures the "after" side against the
# live tree with the same script, and the two are diffed.
#
# Read-only with respect to AWS: `cdk synth --no-lookups` is the only CDK
# command run, so no credentials are needed and no context cache is written.
#
# Usage:
#   scripts/dev/capture-baseline.sh <output-dir> <source-tree> [label]
#
#   output-dir   where artifacts are written (created if absent)
#   source-tree  repository root to capture (a git worktree or the live tree)
#   label        suffix for the tests/names files (default: before)
#
# Example:
#   git worktree add /tmp/cp-pre HEAD
#   cp config/accounts.json /tmp/cp-pre/config/accounts.json
#   scripts/dev/capture-baseline.sh /tmp/cp-baseline /tmp/cp-pre before
#
# Artifacts:
#   <output-dir>/synth/<app>.json      all stacks of one app, keyed by stack name
#   <output-dir>/synth/<app>.log       synth stdout+stderr
#   <output-dir>/tests-<label>.txt     one row per suite: counts + status
#   <output-dir>/tests/<suite>.log     raw runner output per suite
#   <output-dir>/names-<label>.txt     SSM parameter and CFN export names
#   <output-dir>/capture-<label>.log   summary of what ran and what failed
#
# Account IDs: this script writes synthesized templates, which contain real
# account IDs. Keep <output-dir> outside the repository (e.g. under /tmp).
#
# Comparing two captures: asset hashes depend on every file in the asset's build
# context, including untracked ones. Capturing the live tree therefore reports
# different `S3Key` / `aws:asset:path` / container image digests than a clean
# worktree purely because of `__pycache__`, `*.egg-info` and `.pytest_cache`
# directories — measured on this repo as 3 differing values in `agents/infra`
# and none elsewhere. Capture both sides from clean worktrees, or normalize
# asset digests before diffing (decision D6 in the centralized-parameters
# design covers the digest change that the refactor itself causes).

set -uo pipefail

usage() {
  # Print the header comment from "Usage:" to the end of the comment block.
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
  exit "${1:-1}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0
[[ $# -ge 2 ]] || usage 1

OUT_DIR="$(mkdir -p "$1" && cd "$1" && pwd)"
SRC_DIR="$(cd "$2" 2>/dev/null && pwd)" || { echo "source-tree not found: $2" >&2; exit 1; }
LABEL="${3:-before}"

CDK_APPS=(
  "agent-spaces"
  "agents/infra"
  "workload/backend/overlay"
  "workload/frontend"
)

SUMMARY="${OUT_DIR}/capture-${LABEL}.log"
: > "$SUMMARY"
FAILURES=0

log() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
fail() { FAILURES=$((FAILURES + 1)); log "FAIL  $*"; }

log "capture-baseline: label=${LABEL}"
log "  source : ${SRC_DIR}"
log "  output : ${OUT_DIR}"
log "  commit : $(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo 'not a git tree')"
log "  date   : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log ""

for tool in jq node npm python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing prerequisite: $tool" >&2; exit 1; }
done

if [[ ! -f "${SRC_DIR}/config/accounts.json" ]]; then
  echo "missing ${SRC_DIR}/config/accounts.json" >&2
  echo "It is git-ignored, so a fresh worktree needs it copied in:" >&2
  echo "  cp config/accounts.json ${SRC_DIR}/config/accounts.json" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Synthesize every CDK app
# ---------------------------------------------------------------------------
# Each app may hold several stacks, so '**' is synthesized into a scratch
# assembly directory and the templates are folded into one object keyed by
# stack name. The scratch directory lives under <output-dir>, never inside the
# source tree, so capturing the live tree does not disturb its cdk.out.

log "== synth"
mkdir -p "${OUT_DIR}/synth"

for app in "${CDK_APPS[@]}"; do
  app_slug="${app//\//-}"
  app_dir="${SRC_DIR}/${app}"
  asm_dir="${OUT_DIR}/synth/.asm-${app_slug}"
  app_log="${OUT_DIR}/synth/${app_slug}.log"

  if [[ ! -d "$app_dir" ]]; then
    fail "synth ${app}: directory not found"
    continue
  fi

  if [[ ! -d "${app_dir}/node_modules" ]]; then
    log "  ${app}: npm ci"
    if ! (cd "$app_dir" && npm ci) >>"$app_log" 2>&1; then
      fail "synth ${app}: npm ci failed (see ${app_log})"
      continue
    fi
  fi

  rm -rf "$asm_dir"
  # --no-lookups keeps this offline: cached cdk.context.json values are used,
  # and any uncached lookup fails loudly instead of calling AWS.
  if ! (cd "$app_dir" && npx cdk synth '**' --no-lookups --output "$asm_dir") >>"$app_log" 2>&1; then
    fail "synth ${app}: cdk synth failed (see ${app_log})"
    continue
  fi

  # Fold every stack template into one object: { "<StackName>": { ...template } }
  acc="${asm_dir}/.folded.json"
  echo '{}' > "$acc"
  fold_ok=1
  shopt -s nullglob
  for tpl in "$asm_dir"/*.template.json; do
    stack="$(basename "$tpl" .template.json)"
    if jq --arg n "$stack" --slurpfile t "$tpl" '. + {($n): $t[0]}' "$acc" > "${acc}.tmp" 2>>"$app_log"; then
      mv "${acc}.tmp" "$acc"
    else
      fold_ok=0
      break
    fi
  done
  shopt -u nullglob

  if [[ "$fold_ok" -ne 1 ]] || [[ "$(jq -r 'length' "$acc")" -eq 0 ]]; then
    fail "synth ${app}: no templates produced (see ${app_log})"
    continue
  fi
  cp "$acc" "${OUT_DIR}/synth/${app_slug}.json"
  rm -rf "$asm_dir"   # the staged assembly (assets included) is large and not needed

  stacks=$(jq -r 'keys | join(", ")' "${OUT_DIR}/synth/${app_slug}.json")
  bytes=$(wc -c < "${OUT_DIR}/synth/${app_slug}.json" | tr -d ' ')
  log "  OK    ${app} -> synth/${app_slug}.json (${bytes} bytes; stacks: ${stacks})"
done
log ""

# ---------------------------------------------------------------------------
# 2. Per-suite test counts
# ---------------------------------------------------------------------------
# Suites are discovered from the source tree rather than listed here, so a new
# suite is captured on both sides without editing this script.

log "== tests"
mkdir -p "${OUT_DIR}/tests"
TESTS_FILE="${OUT_DIR}/tests-${LABEL}.txt"
{
  printf '# per-suite test counts (label=%s, commit=%s)\n' \
    "$LABEL" "$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf '# %-42s %-7s %6s %6s %6s %6s\n' suite runner total passed failed errors
} > "$TESTS_FILE"

record_test_row() {
  printf '%-44s %-7s %6s %6s %6s %6s  %s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$TESTS_FILE"
}

# --- jest suites: every CDK app with a jest config
while IFS= read -r cfg; do
  suite="${cfg%/jest.config.js}"
  suite="${suite#./}"
  slug="${suite//\//-}"
  suite_log="${OUT_DIR}/tests/${slug}-jest.log"
  json_out="${OUT_DIR}/tests/${slug}-jest.json"

  if [[ ! -d "${SRC_DIR}/${suite}/node_modules" ]]; then
    log "  ${suite}: npm ci"
    (cd "${SRC_DIR}/${suite}" && npm ci) >>"$suite_log" 2>&1 || true
  fi

  (cd "${SRC_DIR}/${suite}" && npx jest --ci --json --outputFile="$json_out") \
    >"$suite_log" 2>&1
  status=$?

  if [[ -f "$json_out" ]]; then
    read -r total passed failed <<<"$(jq -r '[.numTotalTests, .numPassedTests, .numFailedTests] | @tsv' "$json_out")"
    note=$([[ "$status" -eq 0 ]] && echo ok || echo "jest exit ${status}")
    record_test_row "$suite" jest "$total" "$passed" "$failed" 0 "$note"
    log "  ${suite} (jest): ${passed}/${total} passed, ${failed} failed"
    [[ "$status" -eq 0 ]] || fail "tests ${suite}: jest exit ${status}"
  else
    record_test_row "$suite" jest - - - - "no json report (exit ${status}); see tests/${slug}-jest.log"
    fail "tests ${suite}: jest produced no report (exit ${status})"
  fi
done < <(cd "$SRC_DIR" && git ls-files '*jest.config.js' | sort)

# --- pytest suites: every directory holding a tests/ package
while IFS= read -r suite; do
  slug="${suite//\//-}"
  suite_log="${OUT_DIR}/tests/${slug}-pytest.log"

  (cd "${SRC_DIR}/${suite}" && python3 -m pytest -q --tb=no -p no:cacheprovider) \
    >"$suite_log" 2>&1
  status=$?

  # pytest's terminal summary, e.g. "83 passed in 0.26s" or
  # "2 failed, 1 error in 0.4s". Absent counts read as 0.
  summary_line=$(grep -E '^(=+ )?[0-9]+ (passed|failed|error)' "$suite_log" | tail -1)
  [[ -n "$summary_line" ]] || summary_line=$(tail -3 "$suite_log" | tr '\n' ' ')
  count_of() { echo "$summary_line" | grep -oE "[0-9]+ $1" | tail -1 | grep -oE '^[0-9]+'; }
  passed=$(count_of passed); failed=$(count_of failed)
  errors=$(count_of 'error(s)?')
  passed=${passed:-0}; failed=${failed:-0}; errors=${errors:-0}
  total=$((passed + failed + errors))

  note=ok
  if [[ "$status" -ne 0 ]]; then
    if grep -q 'error during collection' "$suite_log"; then
      note="collection error (suite dependencies not installed in this interpreter)"
    else
      note="pytest exit ${status}"
    fi
  fi
  record_test_row "$suite" pytest "$total" "$passed" "$failed" "$errors" "$note"
  log "  ${suite} (pytest): ${passed} passed, ${failed} failed, ${errors} errors — ${note}"
done < <(cd "$SRC_DIR" && git ls-files '*tests/*.py' \
           | sed -E 's|/tests/.*$||' | sort -u)
log ""

# ---------------------------------------------------------------------------
# 3. SSM parameter names and CloudFormation export names
# ---------------------------------------------------------------------------
# Two independent views of each: the names present in the source (what a diff
# of the refactor would touch) and the names present in the synthesized
# templates (what CloudFormation would actually see).

log "== names"
NAMES_FILE="${OUT_DIR}/names-${LABEL}.txt"
{
  printf '# SSM parameter names and CloudFormation export names (label=%s, commit=%s)\n\n' \
    "$LABEL" "$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} > "$NAMES_FILE"

emit_section() { printf '\n## %s\n\n' "$1" >> "$NAMES_FILE"; }

emit_section "SSM parameter names in source (distinct, sorted)"
(cd "$SRC_DIR" && git grep -h -o -E '/(petstore|aiops-poc)/[A-Za-z0-9_.:{}/-]*' -- \
    ':!*/cdk.out/*' ':!.kiro/*' 2>/dev/null) \
  | sed -E 's/[^A-Za-z0-9}]+$//' | sort -u >> "$NAMES_FILE"

emit_section "SSM parameter names in synthesized templates (distinct, sorted)"
for f in "${OUT_DIR}"/synth/*.json; do
  [[ -f "$f" ]] || continue
  jq -r '.. | objects | select(.Type? == "AWS::SSM::Parameter") | .Properties.Name
         | if type == "string" then . else tojson end' "$f" 2>/dev/null
done | sort -u >> "$NAMES_FILE"

emit_section "CloudFormation export names in synthesized templates (distinct, sorted)"
for f in "${OUT_DIR}"/synth/*.json; do
  [[ -f "$f" ]] || continue
  jq -r '.. | objects | select(has("Export")) | .Export.Name
         | if type == "string" then . else tojson end' "$f" 2>/dev/null
done | sort -u >> "$NAMES_FILE"

emit_section "exportName declarations in source (git grep -n)"
(cd "$SRC_DIR" && git grep -n -E 'exportName' -- ':!*/cdk.out/*' 2>/dev/null) >> "$NAMES_FILE"

emit_section "SSM parameter name references in source (git grep -n)"
(cd "$SRC_DIR" && git grep -n -E '/(petstore|aiops-poc)/' -- \
    ':!*/cdk.out/*' ':!.kiro/*' 2>/dev/null) >> "$NAMES_FILE"

ssm_src=$(sed -n '/^## SSM parameter names in source/,/^## SSM parameter names in synth/p' "$NAMES_FILE" \
            | grep -c '^/' || true)
ssm_tpl=$(sed -n '/^## SSM parameter names in synthesized/,/^## CloudFormation export/p' "$NAMES_FILE" \
            | grep -cE '^[^#[:space:]]' || true)
exp_tpl=$(sed -n '/^## CloudFormation export names/,/^## exportName declarations/p' "$NAMES_FILE" \
            | grep -cE '^[^#[:space:]]' || true)
log "  SSM names in source          : ${ssm_src}"
log "  SSM names in templates       : ${ssm_tpl}"
log "  CFN export names in templates: ${exp_tpl}"
log ""

if [[ "$FAILURES" -eq 0 ]]; then
  log "capture-baseline: complete, no failures"
else
  log "capture-baseline: complete with ${FAILURES} failure(s)"
fi
exit "$(( FAILURES > 0 ? 1 : 0 ))"
