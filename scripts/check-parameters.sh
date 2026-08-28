#!/usr/bin/env bash
#
# check-parameters.sh — the completeness proof behind Requirement 1.5.
#
# Four static checks, no AWS calls, no network, bash + jq + a file walk:
#
#   C1  Template self-consistency. The scalar paths of the template's value
#       tree and the keys of its _doc block are the same set, in both
#       directions, and every _doc entry carries the metadata the rest of the
#       tooling reads off it (required, default when optional, description,
#       consumedBy, format, allowed for enumerations).
#   C2  Bash reads are declared. Every config path any shell script reads —
#       through config::get / config::resolve / config::account, or through a
#       raw `jq -r '.x.y' "$CONFIG_FILE"` that bypasses the resolver — appears
#       in the template.
#   C3  CDK reads are declared. The loader's exported FIELDS array is a subset
#       of the template paths, and no file outside config/accounts-config.js
#       reads config/accounts.json itself.
#   C4  Required environment variables have a populator. Every
#       _require_env("NAME") in the Python runtime components has NAME as a key
#       of a CDK environmentVariables / environment block.
#   C5  No new dependency in any manifest (Requirement 10.3).
#   C6  No account, region, or profile literal in any shell script. Every one of
#       those values is a Replicator_Input, so a literal is a value that will be
#       wrong for the next Replicator (Requirements 2.3, 3.5). Plus one narrow
#       Markdown rule: a documented invocation of one of this repository's own
#       scripts must not pass --profile <a template profile default>, because
#       every one of those scripts resolves the profile from
#       config/accounts.json itself. See check_c6 for why that is the only
#       Markdown rule here.
#
# Every failure is collected and printed; the script never stops at the first
# one, and names file:line wherever a source location exists.
#
# Two classes of finding are distinguished in the output, because this feature
# lands in waves and the gate is deliberately installed before the adoption
# tasks it will police:
#
#   FAILURE           a genuine defect — an undeclared input, a missing
#                     populator, a template that documents a field it does not
#                     declare. Exit status 1.
#   PENDING REFACTOR  a known, enumerated state that a later change removes,
#                     rather than a defect: an entry in C3_PENDING_READERS, or a
#                     check that could only pass vacuously. Reported, not fatal
#                     — unless --strict, which promotes every such allowance to
#                     a failure. The adoption waves this gate was installed
#                     ahead of have landed, the registries are empty, and no
#                     pending finding is reported today; the mechanism stays
#                     because the next wave of work may legitimately need it.
#
# Usage:
#   scripts/check-parameters.sh [--strict] [--quiet]
#
#   --strict   Treat every pending-refactor allowance as a failure. Nothing is
#              pending today, so it passes — use it when you want the strongest
#              assertion, and in CI.
#   --quiet    Print only failures and the verdict.
#
# Environment:
#   CHECK_PARAMETERS_ROOT         Repository root to check (default: the
#                                 directory above this script).
#   CHECK_PARAMETERS_BASELINE_REF Git ref C5 compares manifests against
#                                 (default: origin/main, else HEAD).

set -uo pipefail

# ---------------------------------------------------------------------------
# Location and options
# ---------------------------------------------------------------------------

_script_dir() {
  local src="${BASH_SOURCE[0]}"
  cd "$(dirname "$src")" && pwd -P
}

SCRIPT_DIR="$(_script_dir)"
ROOT="${CHECK_PARAMETERS_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}"

STRICT=0
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --quiet)  QUIET=1 ;;
    -h|--help)
      # Print the header comment block and stop at the first line that is not a
      # comment, rather than a hard-coded line count that goes stale every time
      # the header is edited.
      sed -n '2,${/^#/!q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'check-parameters.sh: unknown argument %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

TEMPLATE="${ROOT}/config/accounts.json.template"
LOADER="${ROOT}/config/accounts-config.js"
LOADER_REL="config/accounts-config.js"

# ---------------------------------------------------------------------------
# Pending-refactor registries
#
# Each entry is <path>|<reason>. An entry that no longer applies is itself a
# failure: the list must not outlive the refactor it excuses.
# ---------------------------------------------------------------------------

# Files that still read config/accounts.json directly instead of going through
# the Cdk_Config_Loader. Empty since task 12: all four bin/app.ts entry points
# now call loadAccounts(), so any direct reader is a defect, not a pending item.
C3_PENDING_READERS=()

# ---------------------------------------------------------------------------
# C6 exemptions
#
# Each entry is <path>|<pattern>|<justification>. The pattern is matched as a
# fixed string against the offending text; a finding is excused only when both
# the file and the text match. As with C3_PENDING_READERS, an entry that no
# longer applies is itself a failure, so an exemption cannot outlive its reason.
#
# These are not pending refactors — each is a permanent, argued exception, which
# is why they are excused rather than reported.
# ---------------------------------------------------------------------------
C6_EXEMPT=(
  "scripts/bootstrap.sh|monitoring|case-pattern alias for the --account flag (be|fe|ops), not a CLI profile name"
  "DEPLOYMENT-FINDINGS.md|monitoring|a replication-findings report whose finding 6 IS this defect: it quotes the offending command verbatim as its evidence, and no rule can tell that quotation from the thing it quotes. Delete this entry with the report."
)

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

FAILURES=()
PENDING=()
NOTES=()
CHECK_RESULTS=()

fail()    { FAILURES+=("$1"); }
pending() { PENDING+=("$1"); }
note()    { NOTES+=("$1"); }

# pending_or_fail <message>
#
# One call site for every finding that is a defect after the adoption waves and
# an expected state before them.
pending_or_fail() {
  if [[ "$STRICT" == "1" ]]; then
    fail "$1 [--strict: pending refactor treated as failure]"
  else
    pending "$1"
  fi
}

say() { [[ "$QUIET" == "1" ]] || printf '%s\n' "$1"; }

record() { CHECK_RESULTS+=("$1"); }

# ---------------------------------------------------------------------------
# Repository file walk
#
# Scope is the tracked set plus untracked-but-not-ignored files, so generated
# trees (node_modules/, cdk.out/, dist/) drop out structurally and a brand new
# uncommitted script is still checked. Falls back to find(1) when the root is
# not a git repository of its own, which is what the temp-fixture tests use.
# ---------------------------------------------------------------------------

_repo_files_cache=""

repo_files() {
  if [[ -n "$_repo_files_cache" ]]; then
    printf '%s\n' "$_repo_files_cache"
    return 0
  fi
  local toplevel=""
  if toplevel="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
    toplevel="$(cd "$toplevel" && pwd -P)"
  fi
  if [[ -n "$toplevel" && "$toplevel" == "$ROOT" ]]; then
    _repo_files_cache="$(
      cd "$ROOT" && {
        git ls-files
        git ls-files --others --exclude-standard
      } | sort -u
    )"
  else
    _repo_files_cache="$(
      cd "$ROOT" && find . -type f \
        | sed 's|^\./||' \
        | grep -v -E '(^|/)(\.git|node_modules|cdk\.out|dist|__pycache__|\.venv|venv|\.pytest_cache)/' \
        | sort -u
    )"
  fi
  printf '%s\n' "$_repo_files_cache"
}

# files_matching <extended regex on the path>
files_matching() { repo_files | grep -E "$1" || true; }

# ---------------------------------------------------------------------------
# Template paths
# ---------------------------------------------------------------------------

# Scalar paths of the value tree, skipping any path with an underscore-prefixed
# component. The filter inspects every component, not just the first, so
# operator._comment style prose drops out instead of masquerading as a field.
template_value_paths() {
  jq -r '[ paths(scalars)
           | select(any(.[]; (type == "string") and startswith("_")) | not)
           | map(tostring) | join(".") ] | sort | .[]' "$TEMPLATE"
}

template_doc_paths() {
  jq -r '[ ._doc | keys[] | select(. != "$") ] | sort | .[]' "$TEMPLATE"
}

TEMPLATE_PATHS=""

# declared <dotted.path> -> 0 when the template declares it
declared() {
  printf '%s\n' "$TEMPLATE_PATHS" | grep -qx -- "$1"
}

# ---------------------------------------------------------------------------
# C1 — template self-consistency
# ---------------------------------------------------------------------------

check_c1() {
  if [[ ! -f "$TEMPLATE" ]]; then
    fail "C1: template not found at config/accounts.json.template"
    record "C1 template self-consistency          FAIL (template missing)"
    return
  fi

  if ! jq -e . "$TEMPLATE" >/dev/null 2>&1; then
    fail "config/accounts.json.template: not valid JSON"
    record "C1 template self-consistency          FAIL (invalid JSON)"
    return
  fi

  local before=${#FAILURES[@]}

  local values docs
  values="$(template_value_paths)"
  docs="$(template_doc_paths)"

  if ! jq -e '._doc | type == "object"' "$TEMPLATE" >/dev/null 2>&1; then
    fail "config/accounts.json.template: _doc block is missing or not an object"
  fi
  if ! jq -e '._doc["$"] | type == "string" and length > 0' "$TEMPLATE" >/dev/null 2>&1; then
    fail 'config/accounts.json.template: _doc["$"] must be a non-empty string naming the file as the only file a Replicator edits'
  fi

  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    fail "config/accounts.json.template: value-tree field '${path}' has no _doc entry (add one in the same change — Requirement 1.5)"
  done < <(comm -23 <(printf '%s\n' "$values") <(printf '%s\n' "$docs"))

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    fail "config/accounts.json.template: _doc entry '${path}' documents a field the value tree does not declare"
  done < <(comm -13 <(printf '%s\n' "$values") <(printf '%s\n' "$docs"))

  # Per-entry metadata. Everything downstream reads these: the wizard prompts
  # from description, the resolver validates against format and allowed, the
  # optional-field fallback needs default.
  local line out
  out="$(jq -r '
    def formats: ["accountId","region","profile","email","boolean","string","enum"];
    ._doc | to_entries[] | select(.key != "$")
    | .key as $k | .value as $v
    | if ($v | type) != "object" then
        "_doc[\"\($k)\"] must be an object"
      else
        (
          ( if ($v | has("required")) and (($v.required | type) == "boolean")
            then empty else "_doc[\"\($k)\"] must carry a boolean \"required\"" end ),
          ( if ($v.required == false) and (($v | has("default")) | not)
            then "_doc[\"\($k)\"] is optional and carries no \"default\"" else empty end ),
          ( if ($v.required == true) and ($v | has("default"))
            then "_doc[\"\($k)\"] is required and must not carry a \"default\"" else empty end ),
          ( if ($v | has("description")) and (($v.description | type) == "string") and (($v.description | length) > 0)
            then empty else "_doc[\"\($k)\"] must carry a non-empty \"description\"" end ),
          ( if ($v | has("consumedBy")) and (($v.consumedBy | type) == "array") and (($v.consumedBy | length) > 0)
            then empty else "_doc[\"\($k)\"] must carry a non-empty \"consumedBy\" array" end ),
          ( if ($v | has("format")) | not then "_doc[\"\($k)\"] must carry a \"format\""
            elif (formats | index($v.format)) == null then "_doc[\"\($k)\"] declares unknown format \"\($v.format)\" (expected one of " + (formats | join(", ")) + ")"
            else empty end ),
          ( if ($v.format == "enum") and (($v | has("allowed")) | not)
            then "_doc[\"\($k)\"] declares format enum without \"allowed\"" else empty end ),
          ( if ($v | has("allowed"))
            then ( if (($v.allowed | type) == "array") and (($v.allowed | length) > 0)
                   then empty else "_doc[\"\($k)\"] \"allowed\" must be a non-empty array" end )
            else empty end )
        )
      end
  ' "$TEMPLATE" 2>&1)"
  if [[ $? -ne 0 ]]; then
    fail "config/accounts.json.template: the _doc metadata check could not run: ${out}"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      fail "config/accounts.json.template: ${line}"
    done <<< "$out"
  fi

  # An enumeration nobody can satisfy is worse than no enumeration: the
  # template's own value and the declared default must both be members.
  out="$(jq -r '
    . as $root
    | ._doc | to_entries[] | select(.key != "$")
    | select((.value | type) == "object") | select(.value | has("allowed"))
    | select((.value.allowed | type) == "array")
    | .key as $k | .value as $v
    | ( ($root | getpath($k | split("."))) as $actual
        | if ($actual != null) and (($v.allowed | index($actual)) == null)
          then "value \"\($actual)\" at \($k) is absent from the \"allowed\" enumeration " + ($v.allowed | join(", "))
          else empty end ),
      ( if ($v | has("default")) and (($v.allowed | index($v.default)) == null)
        then "_doc[\"\($k)\"] default \"\($v.default)\" is absent from its own \"allowed\" enumeration"
        else empty end )
  ' "$TEMPLATE" 2>&1)"
  if [[ $? -ne 0 ]]; then
    fail "config/accounts.json.template: the enumeration check could not run: ${out}"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      fail "config/accounts.json.template: ${line}"
    done <<< "$out"
  fi

  local after=${#FAILURES[@]}
  local n_fields n_required
  n_fields="$(printf '%s\n' "$docs" | grep -c . || true)"
  n_required="$(jq -r '[ ._doc | to_entries[] | select(.key != "$") | select(.value.required == true) ] | length' "$TEMPLATE")"
  if [[ "$before" == "$after" ]]; then
    record "C1 template self-consistency          PASS (${n_fields} declared fields, ${n_required} required)"
  else
    record "C1 template self-consistency          FAIL ($((after - before)) problem(s))"
  fi
}

# ---------------------------------------------------------------------------
# C2 — bash reads are declared
#
# Two extractors. The first finds resolver call sites, which is what every
# script looks like after task 11. The second finds raw
# `jq -r '.x.y' "$CONFIG_FILE"` reads, which is both what the scripts look like
# today and how a future script bypassing the resolver would be caught.
# ---------------------------------------------------------------------------

# The resolver library defines the API and documents it with examples; its own
# text is not a call site. Test fixtures live outside the repo tree.
c2_skip_file() {
  case "$1" in
    scripts/lib/config.sh) return 0 ;;
    scripts/check-parameters.sh) return 0 ;;
    *) return 1 ;;
  esac
}

check_c2() {
  local before=${#FAILURES[@]}
  local resolver_sites=0 raw_sites=0
  local raw_files=""
  local file line lineno path role

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    c2_skip_file "$file" && continue
    [[ -f "${ROOT}/${file}" ]] || continue

    # config::get / config::resolve <dotted.path>
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      lineno="${line%%:*}"
      path="$(printf '%s' "${line#*:}" \
        | sed -E "s/.*config::(get|resolve)[[:space:]]+[\"']?([A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*).*/\2/")"
      [[ -n "$path" ]] || continue
      resolver_sites=$((resolver_sites + 1))
      declared "$path" || fail "${file}:${lineno}: config path '${path}' is read here but is not declared in config/accounts.json.template"
    done < <(grep -n -E "config::(get|resolve)[[:space:]]+[\"']?[A-Za-z]" "${ROOT}/${file}" || true)

    # config::account <be|fe|ops> expands to the role's three fields
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      lineno="${line%%:*}"
      role="$(printf '%s' "${line#*:}" | sed -E "s/.*config::account[[:space:]]+[\"']?(be|fe|ops).*/\1/")"
      case "$role" in
        be)  role="backend" ;;
        fe)  role="frontend" ;;
        ops) role="ops" ;;
        *)   continue ;;
      esac
      for path in "${role}.accountId" "${role}.region" "${role}.profile"; do
        resolver_sites=$((resolver_sites + 1))
        declared "$path" || fail "${file}:${lineno}: config path '${path}' is read here but is not declared in config/accounts.json.template"
      done
    done < <(grep -n -E "config::account[[:space:]]+[\"']?(be|fe|ops)([^A-Za-z0-9_]|$)" "${ROOT}/${file}" || true)

    # Raw reads of the parameter file: jq ... '.x.y' "$CONFIG_FILE"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      lineno="${line%%:*}"
      local body="${line#*:}"
      case "$body" in
        *jq*) ;;
        *) continue ;;
      esac
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        raw_sites=$((raw_sites + 1))
        case "$raw_files" in
          *" ${file} "*) ;;
          *) raw_files="${raw_files} ${file} " ;;
        esac
        declared "$path" || fail "${file}:${lineno}: config path '${path}' is read here but is not declared in config/accounts.json.template"
      done < <(printf '%s\n' "$body" \
        | grep -o -E "['\"]\.[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*" \
        | sed -E "s/^['\"]\.//" || true)
    done < <(grep -n -E "jq.*(\\\$\{?(CONFIG|CFG|ACCOUNTS)[A-Z_]*|accounts\.json)" "${ROOT}/${file}" || true)
  done < <(files_matching '\.(sh|bash)$')

  local after=${#FAILURES[@]}
  local n_raw_files
  n_raw_files="$(printf '%s' "$raw_files" | tr ' ' '\n' | grep -c . || true)"
  # Task 11 converted every script to the resolver, so the pending-refactor
  # allowance that used to stand here is gone: a raw read is now a defect
  # whether or not the path it reads is declared. The extractor stays — it is
  # how a future script that bypasses the resolver gets caught.
  if [[ "$raw_sites" -gt 0 ]]; then
    fail "C2: ${raw_sites} raw jq read(s) of the parameter file in ${n_raw_files} script(s) bypass the Config_Resolver — read config/accounts.json only through scripts/lib/config.sh (Requirement 2.6)"
  fi
  if [[ "$before" == "$after" ]]; then
    record "C2 bash reads are declared            PASS (${resolver_sites} resolver read(s), ${raw_sites} raw jq read(s), all declared)"
  else
    record "C2 bash reads are declared            FAIL ($((after - before)) undeclared path read(s))"
  fi
}

# ---------------------------------------------------------------------------
# C3 — CDK reads are declared
# ---------------------------------------------------------------------------

loader_fields() {
  if command -v node >/dev/null 2>&1; then
    node -e '
      const { FIELDS } = require(process.argv[1]);
      if (!Array.isArray(FIELDS)) { process.exit(3); }
      process.stdout.write(FIELDS.join("\n") + "\n");
    ' "$LOADER" 2>/dev/null && return 0
  fi
  # Fallback for an environment with no node: read the literal array.
  sed -n '/^const FIELDS = \[/,/^\];/p' "$LOADER" \
    | grep -o -E "'[A-Za-z][A-Za-z0-9_.]*'" \
    | tr -d "'"
}

# Lines that read config/accounts.json itself. Detection is line-level and
# traces the one indirection real code uses: a const assigned a path literal
# ending in accounts.json, then handed to readFileSync. A file that merely
# mentions the name (a test building a fixture path, a comment) is not a read.
accounts_json_read_lines() {
  local file="$1"
  awk '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (lines[i] ~ /accounts\.json['"'"'"]/ &&
            lines[i] !~ /accounts\.json\.template/ &&
            lines[i] ~ /(const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*(:[^=]*)?=/) {
          name = lines[i]
          sub(/^[ \t]*(const|let|var)[ \t]+/, "", name)
          sub(/[^A-Za-z0-9_$].*$/, "", name)
          if (name != "") pathvar[name] = 1
        }
      }
      for (i = 1; i <= NR; i++) {
        if (lines[i] !~ /readFileSync/) continue
        arg = lines[i]
        sub(/^.*readFileSync[ \t]*\(/, "", arg)
        sub(/[,)].*$/, "", arg)
        gsub(/[ \t]/, "", arg)
        direct = (lines[i] ~ /accounts\.json['"'"'"]/ && lines[i] !~ /accounts\.json\.template/)
        if (direct || (arg in pathvar)) print i ":" lines[i]
      }
    }
  ' "$file"
}

check_c3() {
  local before=${#FAILURES[@]}
  local n_fields=0

  if [[ ! -f "$LOADER" ]]; then
    fail "C3: Cdk_Config_Loader not found at ${LOADER_REL}"
  else
    local field
    while IFS= read -r field; do
      [[ -n "$field" ]] || continue
      n_fields=$((n_fields + 1))
      declared "$field" \
        || fail "${LOADER_REL}: FIELDS entry '${field}' is not declared in config/accounts.json.template"
    done < <(loader_fields)
    if [[ "$n_fields" == "0" ]]; then
      fail "${LOADER_REL}: no FIELDS entries could be read — C3 would be vacuous"
    fi
  fi

  # Negative assertion, with an enumerated pending list for readers a later
  # change is expected to convert. That list is empty today, so any direct
  # reader is a defect.
  local file hit lineno reason entry listed pending_seen=""
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ "$file" == "$LOADER_REL" ]] && continue
    [[ -f "${ROOT}/${file}" ]] || continue
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      lineno="${hit%%:*}"
      listed=0
      reason=""
      # `${a[@]+…}` because /bin/bash here is 3.2, where expanding an empty
      # array under `set -u` is an unbound-variable error — and the list is
      # empty now that task 12 has converted every reader.
      for entry in ${C3_PENDING_READERS[@]+"${C3_PENDING_READERS[@]}"}; do
        if [[ "${entry%%|*}" == "$file" ]]; then
          listed=1
          reason="${entry#*|}"
        fi
      done
      if [[ "$listed" == "1" ]]; then
        pending_or_fail "C3: ${file}:${lineno} reads config/accounts.json directly instead of through the loader — ${reason}"
        case "$pending_seen" in
          *" ${file} "*) ;;
          *) pending_seen="${pending_seen} ${file} " ;;
        esac
      else
        fail "${file}:${lineno}: reads config/accounts.json directly — only ${LOADER_REL} may do that (Requirement 4.1)"
      fi
    done < <(accounts_json_read_lines "${ROOT}/${file}")
  done < <(files_matching '\.(ts|js|mjs|cjs)$')

  # A pending entry that no longer applies must be deleted, or the list quietly
  # becomes a permanent exemption.
  for entry in ${C3_PENDING_READERS[@]+"${C3_PENDING_READERS[@]}"}; do
    file="${entry%%|*}"
    case "$pending_seen" in
      *" ${file} "*) ;;
      *)
        if [[ -f "${ROOT}/${file}" ]]; then
          fail "check-parameters.sh: C3_PENDING_READERS lists ${file}, which no longer reads config/accounts.json — remove the entry"
        fi
        ;;
    esac
  done

  local after=${#FAILURES[@]}
  if [[ "$before" == "$after" ]]; then
    record "C3 CDK reads are declared             PASS (${n_fields} loader field(s), no undocumented direct reader)"
  else
    record "C3 CDK reads are declared             FAIL ($((after - before)) problem(s))"
  fi
}

# ---------------------------------------------------------------------------
# C4 — required environment variables have a populator
# ---------------------------------------------------------------------------

# Keys of every CDK environmentVariables / environment block, following spreads
# of object literals defined in the same file (…commonAgentEnv).
cdk_env_keys() {
  local file="$1"
  awk '
    { lines[NR] = $0 }
    function braces(s,   i, n, c, d) {
      d = 0
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "{") d++
        else if (c == "}") d--
      }
      return d
    }
    function harvest(start,   j, depth, line, key, spread) {
      depth = braces(lines[start])
      if (depth <= 0) return
      for (j = start + 1; j <= NR; j++) {
        line = lines[j]
        if (match(line, /^[ \t]*['"'"'"]?[A-Z][A-Z0-9_]*['"'"'"]?[ \t]*:/)) {
          key = line
          sub(/^[ \t]*/, "", key)
          gsub(/['"'"'"]/, "", key)
          sub(/[ \t]*:.*$/, "", key)
          if (key ~ /^[A-Z][A-Z0-9_]*$/) print key
        }
        if (match(line, /\.\.\.[A-Za-z_$][A-Za-z0-9_$]*/)) {
          spread = substr(line, RSTART + 3, RLENGTH - 3)
          if ((spread in objstart) && !(spread in visited)) {
            visited[spread] = 1
            queue[++qn] = objstart[spread]
          }
        }
        depth += braces(line)
        if (depth <= 0) return
      }
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (lines[i] ~ /(const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*(:[^=]*)?=[ \t]*\{[ \t]*$/) {
          name = lines[i]
          sub(/^[ \t]*(const|let|var)[ \t]+/, "", name)
          sub(/[^A-Za-z0-9_$].*$/, "", name)
          if (name != "") objstart[name] = i
        }
      }
      qn = 0
      for (i = 1; i <= NR; i++) {
        if (lines[i] ~ /(environmentVariables|environment)[ \t]*:[ \t]*\{/) queue[++qn] = i
      }
      for (k = 1; k <= qn; k++) harvest(queue[k])
    }
  ' "$file"
}

check_c4() {
  local before=${#FAILURES[@]}
  local sites=0 keys="" file line lineno name

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ -f "${ROOT}/${file}" ]] || continue
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      keys="${keys} ${name} "
    done < <(cdk_env_keys "${ROOT}/${file}")
  done < <(files_matching '\.ts$' | grep -v -E '(^|/)(test|tests)/' || true)

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    [[ -f "${ROOT}/${file}" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      lineno="${line%%:*}"
      name="$(printf '%s' "${line#*:}" | sed -E "s/.*_require_env\([[:space:]]*[\"']([A-Za-z_][A-Za-z0-9_]*)[\"'].*/\1/")"
      [[ -n "$name" ]] || continue
      sites=$((sites + 1))
      case "$keys" in
        *" ${name} "*) ;;
        *)
          fail "${file}:${lineno}: _require_env(\"${name}\") has no populator — no CDK environmentVariables/environment block sets ${name} (Requirement 5.5)"
          ;;
      esac
    done < <(grep -n -E "_require_env\([[:space:]]*[\"'][A-Za-z_]" "${ROOT}/${file}" || true)
  done < <(files_matching '^(agents|mcp-servers)/.*\.py$')

  local n_keys
  n_keys="$(printf '%s' "$keys" | tr ' ' '\n' | grep -c . || true)"
  if [[ "$sites" == "0" ]]; then
    pending_or_fail "C4: no _require_env() call sites were found, so the check passes vacuously — the Python runtime components are expected to declare every required variable that way. ${n_keys} CDK environment key(s) are indexed and would be matched against them."
  fi

  local after=${#FAILURES[@]}
  if [[ "$before" == "$after" ]]; then
    record "C4 required env vars have populators  PASS (${sites} _require_env site(s) vs ${n_keys} CDK env key(s))"
  else
    record "C4 required env vars have populators  FAIL ($((after - before)) unpopulated variable(s))"
  fi
}

# ---------------------------------------------------------------------------
# C5 — no new dependency in any manifest (Requirement 10.3)
# ---------------------------------------------------------------------------

manifest_deps() {
  # $1 = manifest path (relative), $2 = file contents on stdin
  local rel="$1"
  case "$rel" in
    *package.json)
      jq -r '[(.dependencies // {}), (.devDependencies // {}), (.peerDependencies // {})
              | keys[]] | sort | .[]' 2>/dev/null || true
      ;;
    *pyproject.toml)
      sed -n '/^[[:space:]]*dependencies[[:space:]]*=[[:space:]]*\[/,/\]/p' \
        | grep -o -E '"[^"]+"' \
        | tr -d '"' \
        | sed -E 's/[][<>=!~;, ].*$//' \
        | grep -v '^$' \
        | sort -u
      ;;
    *requirements*.txt)
      sed -E 's/#.*$//' \
        | sed -E 's/[][<>=!~;, ].*$//' \
        | grep -v -E '^[[:space:]]*$' \
        | tr -d ' ' \
        | sort -u
      ;;
  esac
}

check_c5() {
  local before=${#FAILURES[@]}
  local ref="${CHECK_PARAMETERS_BASELINE_REF:-}"
  local toplevel=""
  if toplevel="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
    toplevel="$(cd "$toplevel" && pwd -P)"
  fi
  if [[ -z "$toplevel" || "$toplevel" != "$ROOT" ]]; then
    note "C5: skipped — ${ROOT} is not a git repository, so there is no baseline to diff manifests against."
    record "C5 no new dependency                  SKIP (no git baseline)"
    return
  fi
  if [[ -z "$ref" ]]; then
    if git -C "$ROOT" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
      ref="origin/main"
    else
      ref="HEAD"
    fi
  fi
  if ! git -C "$ROOT" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
    note "C5: skipped — baseline ref '${ref}' does not resolve."
    record "C5 no new dependency                  SKIP (baseline ref ${ref} unresolved)"
    return
  fi

  local file added removed n=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    n=$((n + 1))
    local now base
    now="$(manifest_deps "$file" < "${ROOT}/${file}")"
    if ! base="$(git -C "$ROOT" show "${ref}:${file}" 2>/dev/null | manifest_deps "$file")"; then
      base=""
    fi
    if [[ -z "$base" ]] && ! git -C "$ROOT" cat-file -e "${ref}:${file}" 2>/dev/null; then
      fail "${file}: manifest is new since ${ref} — Requirement 10.3 preserves the existing tooling set"
      continue
    fi
    while IFS= read -r added; do
      [[ -n "$added" ]] || continue
      fail "${file}: dependency '${added}' is new since ${ref} — Requirement 10.3 adds no dependency to any manifest"
    done < <(comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$now"))
    while IFS= read -r removed; do
      [[ -n "$removed" ]] || continue
      note "C5: ${file}: dependency '${removed}' present at ${ref} is gone (removal is not a Requirement 10.3 violation, but confirm it is intended)."
    done < <(comm -23 <(printf '%s\n' "$base") <(printf '%s\n' "$now"))
  done < <(files_matching '(package\.json|pyproject\.toml|requirements[^/]*\.txt)$' | grep -v -E '(^|/)(node_modules|cdk\.out|dist)/' || true)

  local after=${#FAILURES[@]}
  if [[ "$before" == "$after" ]]; then
    record "C5 no new dependency                  PASS (${n} manifest(s) vs ${ref})"
  else
    record "C5 no new dependency                  FAIL ($((after - before)) new dependency/manifest)"
  fi
}

# ---------------------------------------------------------------------------
# C6 — no account, region, or profile literal in any shell script
#
# The three values a Replicator must supply are exactly the three a script must
# never spell out: an account identifier, a region, and a CLI profile name. Task
# 11 removed the last of them, and this check is what keeps them out.
#
# Three rules, each with a deliberate boundary:
#
#   accounts   any 12-digit run, except the canonical placeholder identifiers
#              (111111111111 / 222222222222 / 333333333333), which are the
#              agreed stand-ins and appear in synthetic payloads on purpose.
#   regions    an enumerated partition/direction shape rather than a list of
#              region names, so a region AWS launches tomorrow is still caught.
#              This is a detector, not a validator — the resolver deliberately
#              has no region regex, because rejecting an unknown-but-real region
#              is a different and worse failure than failing to flag a literal.
#   profiles   the profile names the template declares as its defaults, read
#              from the template at runtime. Nothing about the parameter surface
#              is written down here, so renaming a default profile in the
#              template needs no change to this check.
#
# Comments are out of scope for the region and profile rules: prose naming the
# ops profile or a region is documentation, not a value a script will use. An
# account identifier is checked everywhere, comment or not — a real one pasted
# into a comment is exactly the leak Requirement 6.5 is about.
#
# ── The Markdown rule, and its deliberately narrow scope ────────────────────
#
# Documentation is where this class of literal actually reaches a Replicator: a
# copy-pasteable `--profile monitoring` gets pasted, and `monitoring` is only the
# template's default for ops.profile, so it fails with a credentials error that
# reads like an account problem. Exactly one Markdown shape is checked:
#
#     a line that invokes one of this repository's own shell scripts AND passes
#     --profile <one of the profile names the template ships>
#
# That shape is unambiguously wrong and needs no judgment: every script in this
# repository resolves its profile from config/accounts.json, so the flag is
# redundant even when the literal happens to be right, and the fix is always to
# delete it. The script set is read from the repository walk, so documenting a
# new script puts it under the rule with no change here.
#
# What is deliberately NOT checked, and why a wider rule would be worse than
# none:
#
#   * a raw `aws` / `npx cdk` example, where a profile genuinely has to be
#     passed. The repository convention is to write `--profile <ops.profile>`
#     there, but a literal is not automatically a defect the way it is for a
#     script that resolves its own, so a rule covering these would have to judge
#     placeholder-vs-value;
#   * prose. `docs/deployment.md` explains the default profile names, and the
#     template's own _doc says "create a profile with that name (any credential
#     source works: aws configure, aws sso login, or assumed roles)". Naming the
#     default is not the same as
#     handing someone a command to paste;
#   * `docs/deployment.md`'s dated run-log transcripts, which quote commands as
#     they were run and are historical records the repository does not rewrite.
#     No run-log line matches the shape above today, so nothing has to be
#     excused for them — and that matters, because C6_EXEMPT is keyed on
#     (file, matched text), so one entry for a profile name in a file would
#     excuse every occurrence in that file and blind the gate exactly where new
#     copy-pasteable commands land.
# ---------------------------------------------------------------------------

C6_PLACEHOLDER_IDS="111111111111 222222222222 333333333333"

# The checker is scanned by nothing: it necessarily contains the patterns it
# looks for and the text of its own exemptions.
c6_skip_file() {
  case "$1" in
    scripts/check-parameters.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# Profile names to look for = the names the template ships for every field it
# declares with format "profile": the declared default where there is one, and
# otherwise the template's own value for that path. Read, never written down, so
# renaming a profile in the template needs no change here — and a template that
# makes its profiles required rather than optional is still covered.
c6_profile_names() {
  jq -r '
    . as $root
    | ._doc | to_entries[]
    | select((.value | type) == "object")
    | select(.value.format == "profile")
    | .key as $k | .value as $v
    | (if ($v | has("default")) then $v.default
       else ($root | getpath($k | split("."))) end)
    | select(type == "string" and length > 0)
  ' "$TEMPLATE" | sort -u
}

# c6_findings <file> <region regex> <profile alternation>
#
# "<lineno><TAB><kind><TAB><value>" for every literal in one file. All three
# rules are applied in a single pass, because a per-line fork budget over ~8000
# lines of shell is minutes of wall clock for a check that should cost a second.
#
# Comment handling lives here: a full-line comment is scanned for account
# identifiers and nothing else, and a trailing comment is stripped only when it
# contains no quote character, which leaves a '#' inside a string alone.
c6_findings() {
  awk -v region_re="$2" -v profile_re="$3" '
    # A match counts only when it is not glued to a surrounding word. awk has no
    # \b, and "-" counts as a word character here on purpose: aiops-poc-monitoring
    # names a resource, it does not name the monitoring profile.
    function boundary_ok(s, start, len,   before, after) {
      before = (start > 1) ? substr(s, start - 1, 1) : ""
      after  = substr(s, start + len, 1)
      if (before ~ /[A-Za-z0-9_-]/) return 0
      if (after  ~ /[A-Za-z0-9_-]/) return 0
      return 1
    }
    function scan(line, re, kind, lineno,   s, offset, m, start) {
      s = line
      offset = 0
      while (match(s, re) > 0) {
        m = substr(s, RSTART, RLENGTH)
        start = offset + RSTART
        if (boundary_ok(line, start, RLENGTH)) print lineno "\t" kind "\t" m
        offset = start + RLENGTH - 1
        s = substr(s, RSTART + RLENGTH)
      }
    }
    # Digit runs are scanned as runs and filtered on length, so a 13-digit epoch
    # timestamp is not a 12-digit account identifier with a digit stuck to it.
    function scan_ids(line, lineno,   s, m) {
      s = line
      while (match(s, /[0-9]+/) > 0) {
        m = substr(s, RSTART, RLENGTH)
        if (length(m) == 12) print lineno "\t" "account identifier" "\t" m
        s = substr(s, RSTART + RLENGTH)
      }
    }
    {
      scan_ids($0, NR)
      code = $0
      if (code ~ /^[ \t]*#/) next
      if (code ~ /[ \t]#[^"'"'"']*$/) sub(/[ \t]#[^"'"'"']*$/, "", code)
      if (code ~ /^[ \t]*$/) next
      scan(code, region_re, "region", NR)
      if (profile_re != "") scan(code, profile_re, "CLI profile", NR)
    }
  ' "$1"
}

# Basenames of every shell script the repository walk finds, space-padded for an
# index() test in awk. Read rather than listed, so a script added tomorrow is
# covered the day it is documented.
c6_repo_scripts() {
  local file
  printf ' '
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    printf '%s ' "${file##*/}"
  done < <(files_matching '\.(sh|bash)$')
}

# c6_markdown_findings <file> <profile alternation> <space-padded script basenames>
#
# "<lineno><TAB><profile><TAB><script>" for every documented invocation of one of
# this repository's scripts that passes a profile literal. Both halves must be on
# the same line, which is what keeps the rule off prose and off raw `aws`
# examples.
c6_markdown_findings() {
  awk -v profile_re="$2" -v scripts="$3" '
    function boundary_ok(s, start, len,   before, after) {
      before = (start > 1) ? substr(s, start - 1, 1) : ""
      after  = substr(s, start + len, 1)
      if (before ~ /[A-Za-z0-9_-]/) return 0
      if (after  ~ /[A-Za-z0-9_-]/) return 0
      return 1
    }
    # The script this line invokes, if any: the first basename from the walk that
    # appears in the line preceded by a path or command boundary.
    function invoked_script(line,   n, i, parts, name, at, before) {
      n = split(scripts, parts, " ")
      for (i = 1; i <= n; i++) {
        name = parts[i]
        if (name == "") continue
        at = index(line, name)
        while (at > 0) {
          before = (at > 1) ? substr(line, at - 1, 1) : ""
          if (before !~ /[A-Za-z0-9_.-]/ || before == "/") return name
          at = index(substr(line, at + length(name)), name)
          if (at > 0) at = at + length(name)
          else break
        }
      }
      return ""
    }
    {
      if (profile_re == "") next
      line = $0
      script = invoked_script(line)
      if (script == "") next
      s = line
      offset = 0
      while (match(s, "--profile[ =]+" profile_re) > 0) {
        m = substr(s, RSTART, RLENGTH)
        start = offset + RSTART
        sub(/^--profile[ =]+/, "", m)
        if (boundary_ok(line, start + RLENGTH - length(m), length(m)))
          print NR "\t" m "\t" script
        offset = start + RLENGTH - 1
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

c6_exempt() { # <file> <text> -> 0 when an enumerated exemption covers it
  local file="$1" text="$2" entry rest
  for entry in "${C6_EXEMPT[@]}"; do
    rest="${entry#*|}"
    if [[ "${entry%%|*}" == "$file" && "${rest%%|*}" == "$text" ]]; then
      return 0
    fi
  done
  return 1
}

check_c6() {
  local before=${#FAILURES[@]}
  local profiles region_re files file findings hit lineno kind value entry
  local scanned=0 profile_alt=""
  C6_SEEN=""

  profiles="$(c6_profile_names)"
  if [[ -z "${profiles//[[:space:]]/}" ]]; then
    fail "C6: the template declares no profile defaults, so the profile-name rule would be vacuous"
  else
    while IFS= read -r value; do
      [[ -n "$value" ]] || continue
      profile_alt="${profile_alt:+${profile_alt}|}${value}"
    done <<< "$profiles"
  fi
  [[ -n "$profile_alt" ]] && profile_alt="(${profile_alt})"

  region_re='(us|eu|ap|sa|ca|me|af|il|cn|mx)-(gov-)?(east|west|north|south|central|northeast|northwest|southeast|southwest)-[0-9]'

  # Each list is materialized into a variable and walked with a here-string
  # rather than a nested `< <(...)`: three levels of process substitution inside
  # one loop is where bash 3.2 starts handing the inner loop an empty FD, and
  # the failure mode there is a check that silently passes.
  files="$(files_matching '\.(sh|bash)$')"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    c6_skip_file "$file" && continue
    [[ -f "${ROOT}/${file}" ]] || continue
    scanned=$((scanned + 1))

    findings="$(c6_findings "${ROOT}/${file}" "$region_re" "$profile_alt")"
    [[ -n "${findings//[[:space:]]/}" ]] || continue
    while IFS=$'\t' read -r lineno kind value; do
      [[ -n "$value" ]] || continue
      if [[ "$kind" == "account identifier" ]]; then
        case " ${C6_PLACEHOLDER_IDS} " in
          *" ${value} "*) continue ;;
        esac
      fi
      if c6_exempt "$file" "$value"; then
        C6_SEEN="${C6_SEEN} ${file}|${value} "
        continue
      fi
      fail "${file}:${lineno}: ${kind} literal '${value}' — resolve it from config/accounts.json through scripts/lib/config.sh (Requirements 2.3, 3.5)"
    done <<< "$findings"
  done <<< "$files"

  # ── Markdown: a documented invocation of one of our own scripts must not pass
  # a profile literal. Scope and reasoning are argued in the header above.
  local scripts_index script md_scanned=0
  scripts_index="$(c6_repo_scripts)"
  if [[ -n "$profile_alt" ]]; then
    files="$(files_matching '\.(md|markdown)$')"
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      [[ -f "${ROOT}/${file}" ]] || continue
      md_scanned=$((md_scanned + 1))

      findings="$(c6_markdown_findings "${ROOT}/${file}" "$profile_alt" "$scripts_index")"
      [[ -n "${findings//[[:space:]]/}" ]] || continue
      while IFS=$'\t' read -r lineno value script; do
        [[ -n "$value" ]] || continue
        if c6_exempt "$file" "$value"; then
          C6_SEEN="${C6_SEEN} ${file}|${value} "
          continue
        fi
        fail "${file}:${lineno}: documented '${script}' invocation passes --profile ${value} — that script resolves the profile from config/accounts.json, so drop the flag (Requirements 2.3, 3.5)"
      done <<< "$findings"
    done <<< "$files"
  fi

  # An exemption whose finding no longer occurs must be deleted, for the same
  # reason C3's pending list is self-cleaning.
  for entry in "${C6_EXEMPT[@]}"; do
    file="${entry%%|*}"
    value="${entry#*|}"
    value="${value%%|*}"
    case "$C6_SEEN" in
      *" ${file}|${value} "*) ;;
      *)
        if [[ -f "${ROOT}/${file}" ]]; then
          fail "check-parameters.sh: C6_EXEMPT lists '${value}' in ${file}, which no longer contains it — remove the entry"
        fi
        ;;
    esac
  done

  local after=${#FAILURES[@]}
  if [[ "$before" == "$after" ]]; then
    record "C6 no account/region/profile literals PASS (${scanned} shell script(s) + ${md_scanned} markdown file(s), $(printf '%s\n' "$profiles" | grep -c . || true) profile name(s) checked)"
  else
    record "C6 no account/region/profile literals FAIL ($((after - before)) literal(s))"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  printf 'check-parameters.sh: jq is required and was not found on PATH\n' >&2
  exit 2
fi

if [[ ! -f "$TEMPLATE" ]]; then
  printf 'check-parameters.sh: no template at %s\n' "$TEMPLATE" >&2
  printf '  expected the parameter template at <root>/config/accounts.json.template\n' >&2
  exit 2
fi

TEMPLATE_PATHS="$(template_value_paths)"

say "check-parameters.sh — parameter surface completeness proof"
say "  root: ${ROOT}"
[[ "$STRICT" == "1" ]] && say "  mode: --strict (pending refactors are failures)"
say ""

check_c1
check_c2
check_c3
check_c4
check_c5
check_c6

if [[ "$QUIET" != "1" ]]; then
  for line in "${CHECK_RESULTS[@]}"; do
    printf '  %s\n' "$line"
  done
  printf '\n'
fi

if [[ ${#NOTES[@]} -gt 0 && "$QUIET" != "1" ]]; then
  printf 'Notes:\n'
  for line in "${NOTES[@]}"; do
    printf '  - %s\n' "$line"
  done
  printf '\n'
fi

if [[ ${#PENDING[@]} -gt 0 && "$QUIET" != "1" ]]; then
  printf 'Pending refactor (%d) — known states a later task of this spec removes, not defects:\n' "${#PENDING[@]}"
  for line in "${PENDING[@]}"; do
    printf '  - %s\n' "$line"
  done
  printf '\n'
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  printf 'FAILURES (%d):\n' "${#FAILURES[@]}"
  for line in "${FAILURES[@]}"; do
    printf '  - %s\n' "$line"
  done
  printf '\n'
  printf 'check-parameters: FAIL — %d defect(s). Every input a component reads must be declared in config/accounts.json.template (Requirement 1.5).\n' "${#FAILURES[@]}"
  exit 1
fi

say "check-parameters: PASS — C1-C6 hold"
if [[ ${#PENDING[@]} -gt 0 ]]; then
  say "  ${#PENDING[@]} pending refactor(s) reported above; --strict treats them as failures."
fi
exit 0
