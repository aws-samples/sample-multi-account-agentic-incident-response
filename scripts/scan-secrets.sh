#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/scan-secrets.sh — Secret_Scan
#
# Fails when a tracked file carries a live identifier: an account identifier
# that is not one of the canonical placeholders (Requirement 6.5), or a resource
# name carrying a CloudFormation-generated suffix.  Reports every finding as
# file:line:value and exits non-zero.
#
#   scripts/scan-secrets.sh            # scan the repository, exit 1 on findings
#   scripts/scan-secrets.sh --quiet    # exit status only, no per-finding output
#
# Scope comes from `git ls-files`, so untracked and ignored paths
# (node_modules/, cdk.out/, .venv/, config/accounts.json, the local credentials
# guide) are outside the scan structurally rather than by pattern list — a new
# build-output directory cannot silently widen the scan, and the .gitignore
# stays the one place that says what is not committed.
#
# Two match classes:
#
#   Account identifier — any 12-digit run in a tracked text file.  The run is
#   not anchored on digit boundaries, so an identifier hidden inside a longer
#   digit string still matches.  The cost of that strictness is the odd false
#   positive, handled by the token masks below rather than by loosening the
#   pattern — a pattern loose enough to skip a long digit run in the middle of
#   an identifier also skips real account ids written in prose.
#
#   CloudFormation-generated resource name — a physical name of the shape
#   CloudFormation produces when no name is given.  Matched by the shapes in
#   CFN_NAME_PATTERNS and then confirmed by is_cfn_generated_name, which is what
#   keeps the rule quiet in a repository whose docs are full of hyphenated stack
#   and service names.  See those two definitions for the false-positive
#   reasoning and for the shape deliberately left out.
#
# Nothing is excluded, by whole file or by value.  A path-scoped baseline
# (scripts/scan-secrets.baseline) exists and can accept an exact (path, value)
# pair, but it is **empty**: decision D3, which accepted the original build's
# real account IDs and generated resource names in docs/deployment.md as
# historical evidence, was REVERSED on security-standards grounds and those
# values were replaced in place with placeholders.  So the gate currently has no
# accepted-value list at all — every tracked line is scanned, and deleting the
# baseline changes no outcome.
#
# Requirements: 6.5, 6.6
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_FILE="${SCRIPT_DIR}/scan-secrets.baseline"
BASELINE_DISPLAY_PATH="scripts/scan-secrets.baseline"

# ─── Allowlist ───────────────────────────────────────────────────────────────
# The canonical Placeholder_Account_Id set: the three values the parameter
# template ships and the only account identifiers a tracked file may contain.
PLACEHOLDER_IDS=(
  "111111111111" # BE  — backend workload account placeholder
  "222222222222" # FE  — frontend workload account placeholder
  "333333333333" # OPS — monitoring/agent account placeholder
)

# AWS-publishes a handful of service-owned account identifiers that legitimately
# appear in policies (ELB access-log delivery accounts, the CloudFront OAI
# account, regional Redshift audit-logging accounts, …).  None appears in this
# repository today, so the slot is named and empty: when one is genuinely needed
# it goes here with the service and region it belongs to, instead of being
# waved through by widening the placeholder rule.
AWS_SERVICE_ACCOUNT_IDS=()

# ─── Enumerated exclusions (Requirement 6.6) ─────────────────────────────────
# A literal list, one justification per entry.  An exclusion nobody can justify
# in one line does not belong here.  Patterns are matched against the
# repository-relative path with bash glob semantics.
#
# The slot is named and EMPTY, and should stay that way.  A whole-file exclusion
# is the widest tool in this script: it switches off every line of a file
# forever, including lines that do not exist yet.  `docs/deployment.md` used to
# be listed here for decision D3, which put the blind spot in the largest and
# fastest-growing file in the repository — precisely where a live identifier is
# most likely to land.  D3 was then narrowed to per-value baseline entries, and
# has since been REVERSED outright on security-standards grounds: the run log's
# identifiers were replaced with placeholders, and scripts/scan-secrets.baseline
# is empty.  Neither slot has anything in it, and neither should.
EXCLUDED_PATHS=()

# ─── CloudFormation-generated resource names ─────────────────────────────────
# When a CDK/CloudFormation resource is created without an explicit name,
# CloudFormation generates a physical name and appends a random suffix.  Such a
# name is a live identifier of a specific deployment — it is not reproducible,
# it is not a placeholder, and it is not caught by the account-id pattern.
#
# Detection is two-stage on purpose.  These patterns extract *candidates*; the
# `is_cfn_generated_name` guard below decides.  Splitting it that way is what
# makes the rule usable in this repository, whose docs and run logs are full of
# hyphenated stack, cluster, service, alarm and skill names that must not trip
# the gate.  Measured against every tracked file at the time of writing, the two
# stages together match exactly the four real physical names in the run log and
# nothing else.
CFN_NAME_PATTERNS=(
  # Full CloudFormation form: <StackName>-<LogicalId><8 hex>-<random>.  The
  # 8-uppercase-hex logical-id hash is the load-bearing part — it is what
  # separates a generated name from a hand-written hyphenated one.  Example
  # shape: DevSomeStack-ResourceLogicalIdAB12CD34-a1B2c3D4e5F6
  '[A-Za-z][A-Za-z0-9]*-[A-Za-z0-9]*[0-9A-F]{8}-[A-Za-z0-9]{12,13}'

  # Truncated form used where the service caps name length (ELB/ALB, target
  # groups): the stack and logical-id parts are cut to a few characters, so the
  # hash is gone and only the random suffix carries the entropy.  Example
  # shape: Abcde-Fghij-a1B2c3D4e5F6.  This shape overlaps with ordinary
  # hyphenated prose, which is exactly what the guard is for.
  '[A-Za-z][A-Za-z0-9]{2,7}-[A-Za-z][A-Za-z0-9]{2,7}-[A-Za-z0-9]{12,16}'
)

# ─── Non-account token masks (Requirement 6.6) ───────────────────────────────
# Some AWS identifiers legitimately carry a long digit run that is not an
# account identifier.  Masking the *token* rather than excluding the file keeps
# the surrounding source in scope: a real identifier elsewhere in the same file
# — or elsewhere on the same line — still fails the scan.  This is deliberately
# narrower than EXCLUDED_PATHS, which switches a whole path off.
NON_ACCOUNT_TOKEN_PATTERNS=(
  # A 64-character lowercase-hex run is a sha256 digest, and roughly one digest
  # in five happens to contain twelve consecutive digits — measured, not
  # theorised: one of the seven entries scripts/scan-secrets.baseline used to
  # carry did.  Without this mask a non-empty baseline would fail the very gate
  # it feeds, and so would any file quoting a digest.  The baseline is empty
  # today, but the mask stays: it is the general rule, not a special case for
  # one file.  Masked by exact digest length rather than
  # as "any long hex run" on purpose, so that a long run of pure DIGITS keeps
  # matching — hiding an identifier inside a longer digit string is the case the
  # unanchored account pattern above exists to catch.
  '[0-9a-f]{64}'

  # VPC endpoint service names end in a 17-character suffix.  The synth-time
  # PrivateLink placeholder in workload/frontend/lib/frontend-stack.ts uses all
  # zeros ('…vpce-svc-00000000000000000'), whose leading twelve digits are
  # shape-identical to an account ID.  That file is production source that could
  # gain a real identifier later, so only the vpce-svc- token is masked.
  'vpce-svc-[0-9a-f]+'
)

QUIET=0

usage() {
  cat <<'EOF'
Usage: scripts/scan-secrets.sh [--quiet]

Scans every tracked text file for live identifiers: 12-digit account
identifiers that are not canonical placeholders, and resource names carrying a
CloudFormation-generated suffix.  Prints file:line:value per finding and exits 1
when there is at least one finding.

scripts/scan-secrets.baseline can accept an exact (path, value) pair, but it is
intentionally EMPTY: nothing in this repository is exempt, including the run
logs, whose identifiers are placeholders.  That file's header explains why, and
what a new entry would have to justify.

  --quiet   Suppress per-finding output; report the count and exit status only
  -h        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet | -q) QUIET=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'scan-secrets: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v git >/dev/null 2>&1; then
  printf 'scan-secrets: git is required to determine the scan scope\n' >&2
  exit 2
fi

if ! git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'scan-secrets: %s is not a git work tree; scope comes from git ls-files\n' \
    "${PROJECT_ROOT}" >&2
  exit 2
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

# True when the repository-relative path matches an enumerated exclusion.
is_excluded() {
  local path="$1" pattern
  for pattern in ${EXCLUDED_PATHS[@]+"${EXCLUDED_PATHS[@]}"}; do
    # shellcheck disable=SC2053  # deliberate glob match against the pattern
    if [[ "${path}" == ${pattern} ]]; then
      return 0
    fi
  done
  return 1
}

# ─── Baseline ────────────────────────────────────────────────────────────────
# Two parallel indexed arrays rather than one associative array: bash 3.2 is the
# floor for this repository, and a path may legitimately carry several accepted
# values, so a path-keyed map would be the wrong shape anyway.
BASELINE_PATHS=()
BASELINE_DIGESTS=()

DIGEST_CMD=""
resolve_digest_cmd() {
  if command -v shasum >/dev/null 2>&1; then
    DIGEST_CMD="shasum"
  elif command -v sha256sum >/dev/null 2>&1; then
    DIGEST_CMD="sha256sum"
  elif command -v openssl >/dev/null 2>&1; then
    DIGEST_CMD="openssl"
  fi
}

# sha256 of the exact value, no trailing newline — the same digest the baseline
# instructions tell a maintainer to produce.
compute_digest() {
  local value="$1"
  case "${DIGEST_CMD}" in
    shasum) printf '%s' "${value}" | shasum -a 256 | cut -d' ' -f1 ;;
    sha256sum) printf '%s' "${value}" | sha256sum | cut -d' ' -f1 ;;
    openssl) printf '%s' "${value}" | openssl dgst -sha256 | sed 's/^.*= *//' ;;
  esac
}

# Memoized digest.  A run log quotes the same handful of values dozens of times,
# so without a cache the scan forks a hash process per occurrence.  bash 3.2 has
# no associative arrays: the cache is one variable per value, named by the
# value's own characters with everything outside [A-Za-z0-9] flattened to `_`,
# and read back through indirect expansion.
value_digest() {
  local value="$1" key safe
  safe="$(printf '%s' "${value}" | tr -c 'A-Za-z0-9' '_')"
  key="_scan_secrets_digest_${safe}"
  if [[ -z "${!key+set}" ]]; then
    printf -v "${key}" '%s' "$(compute_digest "${value}")"
  fi
  printf '%s' "${!key}"
}

# Load the baseline: `<path glob> | <sha256> | <justification>`, `#` comments.
load_baseline() {
  local line path digest rest lineno=0

  [[ -f "${BASELINE_FILE}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    line="${line#"${line%%[![:space:]]*}"}" # left-trim
    [[ -n "${line}" ]] || continue
    [[ "${line:0:1}" == "#" ]] && continue

    if [[ "${line}" != *"|"*"|"* ]]; then
      printf 'scan-secrets: %s:%d: expected `<path> | <sha256> | <why>`\n' \
        "${BASELINE_DISPLAY_PATH}" "${lineno}" >&2
      exit 2
    fi

    path="${line%%|*}"
    rest="${line#*|}"
    digest="${rest%%|*}"

    # Trim surrounding whitespace off both fields.
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    digest="${digest#"${digest%%[![:space:]]*}"}"
    digest="${digest%"${digest##*[![:space:]]}"}"

    if [[ ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
      printf 'scan-secrets: %s:%d: second field is not a lowercase sha256 hex digest\n' \
        "${BASELINE_DISPLAY_PATH}" "${lineno}" >&2
      exit 2
    fi

    BASELINE_PATHS+=("${path}")
    BASELINE_DIGESTS+=("${digest}")
  done <"${BASELINE_FILE}"

  if [[ "${#BASELINE_DIGESTS[@]}" -gt 0 && -z "${DIGEST_CMD}" ]]; then
    printf 'scan-secrets: %s has entries but no sha256 tool is available (shasum, sha256sum or openssl) — refusing to scan with an unenforceable baseline\n' \
      "${BASELINE_DISPLAY_PATH}" >&2
    exit 2
  fi
}

# True when this exact value is accepted for this exact path by the baseline.
# Path globs are matched with the same semantics as EXCLUDED_PATHS; the value
# must match a digest listed against a matching path, so accepting a value in a
# run log does not accept it in source.
is_baselined() {
  local path="$1" value="$2" digest="" i

  [[ "${#BASELINE_DIGESTS[@]}" -gt 0 ]] || return 1

  for ((i = 0; i < ${#BASELINE_PATHS[@]}; i++)); do
    # shellcheck disable=SC2053  # deliberate glob match against the pattern
    [[ "${path}" == ${BASELINE_PATHS[i]} ]] || continue
    [[ -n "${digest}" ]] || digest="$(value_digest "${value}")"
    if [[ "${digest}" == "${BASELINE_DIGESTS[i]}" ]]; then
      return 0
    fi
  done
  return 1
}

# Confirm a CFN_NAME_PATTERNS candidate really is a generated physical name.
# The decision rests on the last hyphen-separated segment, which is where
# CloudFormation puts its random suffix.  Three conditions, each earning its
# place against a false-positive class actually present in this repository:
#
#   an uppercase letter — ordinary hyphenated prose, anchors, skill and scenario
#     names, and package names in this repo are lowercase (`ddb-throttle`,
#     `checkout-latency-investigation`, `accounts-and-prerequisites`);
#   a digit — rules out CamelCase identifiers and class-like names;
#   a letter outside the hex alphabet — rules out every hex string, which is the
#     class that would otherwise be caught wholesale: investigation UUIDs, git
#     SHAs, CDK asset digests and CloudFront/experiment ids.  A generated suffix
#     is base-36-ish, so drawing 12+ characters entirely from [0-9A-Fa-f] is
#     rare enough to accept as a miss.
#
# Character classes are POSIX-named or explicitly enumerated rather than ranged,
# so a collation order other than ASCII cannot change what matches.
is_cfn_generated_name() {
  local suffix="${1##*-}"
  [[ "${suffix}" == *[[:upper:]]* ]] || return 1
  [[ "${suffix}" == *[[:digit:]]* ]] || return 1
  [[ "${suffix}" == *[GHIJKLMNOPQRSTUVWXYZghijklmnopqrstuvwxyz]* ]] || return 1
  return 0
}

# Emit the file with every non-account token replaced by a digit-free marker.
# `sed s///` is line-preserving, so grep's line numbers still refer to the file
# on disk.  Only ever called for a file the first pass already proved to be
# text, so sed never meets a byte sequence it would refuse.
mask_non_account_tokens() {
  local path="$1" pattern
  local -a args=()
  for pattern in "${NON_ACCOUNT_TOKEN_PATTERNS[@]}"; do
    args+=(-e "s/${pattern}/<non-account-token>/g")
  done
  sed -E "${args[@]}" "${path}"
}

# True when a matched 12-digit value is allowed to appear in a tracked file.
is_allowed_id() {
  local value="$1" allowed
  for allowed in "${PLACEHOLDER_IDS[@]}" ${AWS_SERVICE_ACCOUNT_IDS[@]+"${AWS_SERVICE_ACCOUNT_IDS[@]}"}; do
    if [[ "${value}" == "${allowed}" ]]; then
      return 0
    fi
  done
  return 1
}

# ─── Scan ────────────────────────────────────────────────────────────────────

resolve_digest_cmd
load_baseline

# One alternation, so a file is read once for the whole class.
#
# The IFS assignment below is scoped to the command-substitution subshell, so
# it never reaches the parent shell — this is the standard bash idiom for
# joining an array with a separator, not global IFS tampering. Suppressed
# rather than rewritten because the alternatives (a loop, or `tr`) are less
# readable for no safety gain.
CFN_NAME_RE="$(
  # nosemgrep: bash.lang.security.ifs-tampering
  IFS='|'
  printf '%s' "${CFN_NAME_PATTERNS[*]}"
)"

findings=0
scanned=0

report() {
  findings=$((findings + 1))
  if [[ "${QUIET}" -eq 0 ]]; then
    printf '%s:%s:%s\n' "$1" "$2" "$3"
  fi
}

while IFS= read -r -d '' file; do
  abs="${PROJECT_ROOT}/${file}"
  [[ -f "${abs}" ]] || continue # staged deletion, submodule, …
  is_excluded "${file}" && continue

  # One text/binary decision per file, taken by grep itself: -I makes grep treat
  # a binary file as non-matching, so the empty pattern matches every line of a
  # text file and nothing at all in a binary.  Deciding it here rather than as a
  # side effect of the first pattern is what lets both match classes share the
  # same binary skip.
  grep -Iq '' -- "${abs}" 2>/dev/null || continue
  scanned=$((scanned + 1))

  # ── Account identifiers ────────────────────────────────────────────────────
  # -o -n reports LINE:VALUE per match.
  matches="$(grep -InoE '[0-9]{12}' -- "${abs}" 2>/dev/null || true)"
  if [[ -n "${matches}" ]]; then
    # Second pass over the same file with the non-account tokens masked.  Running
    # it only for files the first pass matched costs nothing on the overwhelming
    # majority of files.
    matches="$(mask_non_account_tokens "${abs}" | grep -InoE '[0-9]{12}' || true)"
    while IFS=: read -r lineno value; do
      [[ -n "${value}" ]] || continue
      is_allowed_id "${value}" && continue
      is_baselined "${file}" "${value}" && continue
      report "${file}" "${lineno}" "${value}"
    done <<<"${matches}"
  fi

  # ── CloudFormation-generated resource names ────────────────────────────────
  # LC_ALL=C so the hex and alphanumeric ranges in the patterns mean the same
  # thing whatever the caller's locale collates to.
  matches="$(LC_ALL=C grep -InoE "${CFN_NAME_RE}" -- "${abs}" 2>/dev/null || true)"
  if [[ -n "${matches}" ]]; then
    while IFS=: read -r lineno value; do
      [[ -n "${value}" ]] || continue
      is_cfn_generated_name "${value}" || continue
      is_baselined "${file}" "${value}" && continue
      report "${file}" "${lineno}" "${value}"
    done <<<"${matches}"
  fi
done < <(git -C "${PROJECT_ROOT}" ls-files -z)

if [[ "${findings}" -gt 0 ]]; then
  printf 'scan-secrets: %d finding(s) in %d scanned file(s)\n' \
    "${findings}" "${scanned}" >&2
  exit 1
fi

if [[ "${QUIET}" -eq 0 ]]; then
  printf 'scan-secrets: clean — %d tracked file(s) scanned, no unaccepted account identifiers or generated resource names\n' \
    "${scanned}"
fi
exit 0
