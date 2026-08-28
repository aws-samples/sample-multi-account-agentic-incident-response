#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/config.sh — Config_Resolver
#
# The single shared location every Deployment_Script uses to resolve a
# Replicator_Input (Requirement 2.6).  Sourced, never executed:
#
#   source "${PROJECT_ROOT}/scripts/lib/config.sh"
#   config::init
#   config::account be              # -> CONFIG_BE_ACCOUNT / _REGION / _PROFILE
#   REGION="$(config::get ops.region "${REGION_FLAG:-}")"
#
# Public interface
#   config::init [--config PATH] [--template PATH]
#   config::get <json.path> [flag_value]
#   config::resolve <json.path> [flag_value]   # record without printing
#   config::account <be|fe|ops> [--profile-flag V] [--region-flag V]
#   config::origin <json.path>            # "env (AIOPS_OPS_REGION)"
#   config::origin_level <json.path>      # flag | env | file | default
#   config::dump [--redact]
#   config::aws <be|fe|ops> [--] <aws args...>
#   config::is_placeholder <json.path> <value>
#   config::use_legacy_aliases            # optional, unused: bare PROFILE / REGION
#
# Precedence: command-line flag > environment variable > config file >
# template default (Requirement 2.1).  The winning level and its detail are
# recorded per path for config::origin and config::dump (Requirement 2.5).
#
# Every declaration — which fields exist, which are required, and what an
# optional field defaults to — is read from config/accounts.json.template at
# runtime.  Nothing about the parameter surface is written down here, so a
# field added to the template needs no change to this file (Requirement 1.5).
#
# All diagnostics go to stderr so that "$(config::get …)" stays clean.
# Failures exit non-zero and name the JSON path or the missing prerequisite
# (Requirements 3.1-3.4).  No account identifier, region name, or CLI profile
# name appears as a literal anywhere in this file (Requirement 3.5).
#
# Requirements: 2.1, 2.5, 2.6, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6
# ─────────────────────────────────────────────────────────────────────────────

# Idempotent sourcing — several scripts source this indirectly.
if [[ -n "${_CONFIG_SH_SOURCED:-}" ]]; then
  return 0
fi
_CONFIG_SH_SOURCED=1

# ─── Legacy environment aliases ──────────────────────────────────────────────
# An optional opt-in that lets bare PROFILE and REGION resolve at the env
# precedence level, after the canonical AIOPS_* names, through this one
# enumerated list.  The alias key is the last component of a JSON path, so
# PROFILE covers backend.profile, frontend.profile and ops.profile alike.
# No script in this repository opts in: every pre-refactor script assigned
# PROFILE="" / REGION="" before use, so none of them ever read those names from
# the environment, and enabling the aliases would add an override path rather
# than preserve one.  The mechanism is kept, unused, for callers that want it.
_CONFIG_LEGACY_ALIAS_KEYS=("profile" "region")
_CONFIG_LEGACY_ALIAS_VAR_profile="PROFILE"
_CONFIG_LEGACY_ALIAS_VAR_region="REGION"
_CONFIG_LEGACY_ENABLED=0

# ─── Placeholder patterns ────────────────────────────────────────────────────
# The canonical placeholder account IDs plus the two placeholder prefixes the
# template uses.  A value is also a placeholder when it still equals the
# template's own value for the same path and that field's format makes sharing
# impossible (see _config__template_equality_applies).
_CONFIG_PLACEHOLDER_ID_RE='^(1{12}|2{12}|3{12})$'
_CONFIG_PLACEHOLDER_PREFIX_RE='^(REPLACE_WITH_|your-)'

# ─── Value shape patterns ────────────────────────────────────────────────────
# One pattern per declared format that has a shape.  Which field carries which
# format is never written here — it is read from the template's _doc block, so a
# field added to the template is validated without touching this file.
#
# KEEP IN SYNC with ACCOUNT_ID_PATTERN / EMAIL_PATTERN and _config__validate's
# counterpart `validateValue` in config/accounts-config.js: the two resolvers
# must accept and reject exactly the same values, the same way the placeholder
# rule is cross-referenced above.
#
# region, profile and string are deliberately shape-free beyond "non-empty after
# trimming": a newly launched AWS region must not require a change here.
_CONFIG_ACCOUNT_ID_RE='^[0-9]{12}$'
_CONFIG_EMAIL_RE='^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$'
_CONFIG_BOOLEAN_RE='^(true|false)$'

_CONFIG_INITIALIZED=0
_CONFIG_DECLARED_PATHS=""

# ─── Internals ───────────────────────────────────────────────────────────────

# Print a diagnostic and exit non-zero.  stderr only.
_config__die() {
  printf 'ERROR [config]: %s\n' "$1" >&2
  shift
  while [[ $# -gt 0 ]]; do
    printf '  %s\n' "$1" >&2
    shift
  done
  exit 1
}

_config__warn() {
  printf 'WARN  [config]: %s\n' "$1" >&2
}

# JSON path -> variable-name suffix.  "ops.region" -> "ops_region"
_config__key() {
  local path="$1"
  printf '%s' "${path//[^A-Za-z0-9]/_}"
}

# JSON path -> canonical environment variable name, derived mechanically.
# "ops.region" -> AIOPS_OPS_REGION ; "backend.accountId" -> AIOPS_BACKEND_ACCOUNTID
_config__env_name() {
  local path="$1"
  local upper
  upper="$(printf '%s' "$path" | tr 'a-z.' 'A-Z_')"
  printf 'AIOPS_%s' "$upper"
}

# Store a value under a dynamic variable name (bash 3.2 has no associative
# arrays; these prefixed variables are the three parallel maps the design
# describes, keyed by the sanitized JSON path).
_config__set() {
  printf -v "$1" '%s' "$2"
}

# Print the value of a dynamic variable; return 1 when it is unset.
_config__var() {
  local name="$1"
  if [[ -n "${!name+x}" ]]; then
    printf '%s' "${!name}"
    return 0
  fi
  return 1
}

_config__is_set() {
  local name="$1"
  [[ -n "${!name+x}" ]]
}

_config__ensure_init() {
  if [[ "${_CONFIG_INITIALIZED}" != "1" ]]; then
    _config__die "config::init has not been called" \
      "Source scripts/lib/config.sh and call config::init before resolving inputs."
  fi
}

# Records are delimited by the ASCII unit separator rather than by a tab: tab is
# an IFS whitespace character, so `read` would collapse consecutive tabs and an
# empty field (a required field has no default) would shift every later column.
_CONFIG_FS=$'\x1f'

# Members of an `allowed` list are joined with the ASCII record separator inside
# the single field the _doc reader emits for them, for the same reason.
_CONFIG_RS=$'\x1e'

# Flatten a JSON document to "path<FS>value" lines, skipping any path with an
# underscore-prefixed component so that _doc and any nested _comment drop out.
_config__flatten() {
  local file="$1"
  jq -r '
    paths(scalars) as $p
    | select([$p[] | select(type == "string" and startswith("_"))] | length == 0)
    | (($p | map(tostring) | join(".")) + "\u001f" + (getpath($p) | tostring))
  ' "$file"
}

# Read the template _doc block as
# "path<FS>required<FS>hasDefault<FS>default<FS>format<FS>allowed", where allowed
# is the enum domain joined with <RS> and empty when the entry declares none.
_config__read_doc() {
  local file="$1"
  jq -r '
    (._doc // {})
    | to_entries[]
    | select(.value | type == "object")
    | .key + "\u001f"
      + ((.value.required // false) | tostring) + "\u001f"
      + (if (.value | has("default")) then "1" else "0" end) + "\u001f"
      + (if (.value | has("default")) then (.value.default | tostring) else "" end) + "\u001f"
      + (.value.format // "string") + "\u001f"
      + ((.value.allowed // []) | map(tostring) | join("\u001e"))
  ' "$file"
}

_config__load_template() {
  local doc_lines tpl_lines path required has_default default format allowed value
  doc_lines="$(_config__read_doc "${CONFIG_TEMPLATE_PATH}")" || _config__die \
    "could not parse ${CONFIG_TEMPLATE_DISPLAY_PATH}" "jq failed to read the template as JSON."
  tpl_lines="$(_config__flatten "${CONFIG_TEMPLATE_PATH}")" || _config__die \
    "could not parse ${CONFIG_TEMPLATE_DISPLAY_PATH}" "jq failed to read the template as JSON."

  local declared=""
  while IFS="${_CONFIG_FS}" read -r path required has_default default format allowed; do
    [[ -z "$path" ]] && continue
    local key
    key="$(_config__key "$path")"
    _config__set "_CONFIG_TPL_REQUIRED__${key}" "$required"
    _config__set "_CONFIG_TPL_HASDEFAULT__${key}" "$has_default"
    _config__set "_CONFIG_TPL_DEFAULT__${key}" "$default"
    _config__set "_CONFIG_TPL_FORMAT__${key}" "$format"
    _config__set "_CONFIG_TPL_ALLOWED__${key}" "$allowed"
    _config__set "_CONFIG_TPL_DECLARED__${key}" "1"
    declared="${declared}${path}
"
  done <<< "$doc_lines"

  while IFS="${_CONFIG_FS}" read -r path value; do
    [[ -z "$path" ]] && continue
    local key
    key="$(_config__key "$path")"
    _config__set "_CONFIG_TPL_VALUE__${key}" "$value"
  done <<< "$tpl_lines"

  if [[ -z "${declared//[[:space:]]/}" ]]; then
    _config__die "${CONFIG_TEMPLATE_DISPLAY_PATH} declares no fields" \
      "The template needs a _doc block declaring every field. See docs/parameters.md."
  fi
  _CONFIG_DECLARED_PATHS="$(printf '%s' "$declared" | sort)"
}

_config__load_config_file() {
  local lines path value key
  lines="$(_config__flatten "${CONFIG_FILE_PATH}")" || _config__die \
    "could not parse ${CONFIG_FILE_DISPLAY_PATH}" "The file is not valid JSON."
  while IFS="${_CONFIG_FS}" read -r path value; do
    [[ -z "$path" ]] && continue
    key="$(_config__key "$path")"
    _config__set "_CONFIG_FILE_VALUE__${key}" "$value"
  done <<< "$lines"
}

# The template's own value is treated as a placeholder only for formats where a
# real configuration can never legitimately repeat it.  A profile name or a
# region in a real config commonly equals the template's, so those are judged
# by the placeholder patterns alone.
_config__template_equality_applies() {
  local format="$1"
  [[ "$format" == "accountId" || "$format" == "email" ]]
}

# Strip leading and trailing whitespace.  Shape checks run against the trimmed
# form so that a padded value is judged the way the CDK loader judges it — the
# loader trims every string as it resolves it.
_config__trim() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

# _config__validate <json.path> <value>
#
# Check one resolved value against the format and the enum domain the template
# declares for its path.  Returns 0 when the value is acceptable; otherwise sets
# _CONFIG_VALIDATION_HINT to the expected form and returns non-zero.
#
# KEEP IN SYNC with validateValue in config/accounts-config.js — a value accepted
# by one resolver must be accepted by the other, or a hand-edited config would
# deploy through one path and fail through the other.
_config__validate() {
  local path="$1"
  local value="$2"
  local key format allowed trimmed lower item list matched

  key="$(_config__key "$path")"
  format="$(_config__var "_CONFIG_TPL_FORMAT__${key}" || printf 'string')"
  allowed="$(_config__var "_CONFIG_TPL_ALLOWED__${key}" || printf '')"
  trimmed="$(_config__trim "$value")"
  _CONFIG_VALIDATION_HINT=""

  case "$format" in
    accountId)
      if [[ ! "$trimmed" =~ $_CONFIG_ACCOUNT_ID_RE ]]; then
        _CONFIG_VALIDATION_HINT="Expected exactly 12 decimal digits (declared format: accountId)."
        return 1
      fi
      ;;
    email)
      if [[ ! "$trimmed" =~ $_CONFIG_EMAIL_RE ]]; then
        _CONFIG_VALIDATION_HINT="Expected an address of the form name@example.com (declared format: email)."
        return 1
      fi
      ;;
    boolean)
      lower="$(printf '%s' "$trimmed" | tr 'A-Z' 'a-z')"
      if [[ ! "$lower" =~ $_CONFIG_BOOLEAN_RE ]]; then
        _CONFIG_VALIDATION_HINT="Expected true or false (declared format: boolean)."
        return 1
      fi
      ;;
    *)
      # region, profile, string: non-empty is the whole rule. No region regex —
      # a region AWS launches tomorrow must resolve without a change here.
      if [[ -z "$trimmed" ]]; then
        _CONFIG_VALIDATION_HINT="Expected a non-empty value (declared format: ${format})."
        return 1
      fi
      ;;
  esac

  if [[ -n "$allowed" ]]; then
    matched=0
    list=""
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      list="${list:+${list}, }${item}"
      if [[ "$trimmed" == "$item" ]]; then
        matched=1
      fi
    done <<< "$(printf '%s' "$allowed" | tr "${_CONFIG_RS}" '\n')"
    if [[ "$matched" != "1" ]]; then
      _CONFIG_VALIDATION_HINT="Expected one of: ${list}."
      return 1
    fi
  fi

  return 0
}

# Resolve one path, recording the winning level.  Runs in the caller's shell so
# the record survives; config::get wraps it for command substitution.
#   $1 path   $2 flag value (may be empty)   $3 soft (1 = report, do not exit)
# Sets _CONFIG_RESOLVED_VALUE / _CONFIG_RESOLVED_ORIGIN /
# _CONFIG_RESOLVED_ORIGIN_DETAIL and returns non-zero in soft mode on failure.
_config__resolve() {
  local path="$1"
  local flag="${2:-}"
  local soft="${3:-0}"
  local key value origin detail env_name required format

  key="$(_config__key "$path")"

  # Already resolved and no new flag to consider: replay the record.  This is
  # what keeps the origin reported by config::origin equal to the origin that
  # actually supplied the value, even though config::get is normally called in
  # a command substitution whose own record would be discarded.
  if [[ -z "$flag" ]] && _config__is_set "_CONFIG_VALUE__${key}"; then
    _CONFIG_RESOLVED_VALUE="$(_config__var "_CONFIG_VALUE__${key}")"
    _CONFIG_RESOLVED_ORIGIN="$(_config__var "_CONFIG_ORIGIN__${key}")"
    _CONFIG_RESOLVED_ORIGIN_DETAIL="$(_config__var "_CONFIG_ORIGIN_DETAIL__${key}" || printf '')"
    return 0
  fi

  if ! _config__is_set "_CONFIG_TPL_DECLARED__${key}"; then
    local msg="config path '${path}' is not declared in the template"
    if [[ "$soft" == "1" ]]; then
      _CONFIG_RESOLVED_VALUE=""
      _CONFIG_RESOLVED_ORIGIN="UNDECLARED"
      _CONFIG_RESOLVED_ORIGIN_DETAIL="${CONFIG_TEMPLATE_DISPLAY_PATH}"
      _config__warn "$msg"
      return 1
    fi
    _config__die "$msg" \
      "Add a _doc entry for '${path}' to ${CONFIG_TEMPLATE_DISPLAY_PATH}."
  fi

  required="$(_config__var "_CONFIG_TPL_REQUIRED__${key}" || printf 'false')"
  format="$(_config__var "_CONFIG_TPL_FORMAT__${key}" || printf 'string')"

  value=""
  origin=""
  detail=""

  # 1. command-line flag
  if [[ -n "$flag" ]]; then
    value="$flag"
    origin="flag"
    detail="command line"
  fi

  # 2. environment — canonical name first, then an opted-in legacy alias
  if [[ -z "$origin" ]]; then
    env_name="$(_config__env_name "$path")"
    if [[ -n "${!env_name:-}" ]]; then
      value="${!env_name}"
      origin="env"
      detail="$env_name"
    elif [[ "${_CONFIG_LEGACY_ENABLED}" == "1" ]]; then
      local leaf alias_var alias_name
      leaf="${path##*.}"
      for alias_name in "${_CONFIG_LEGACY_ALIAS_KEYS[@]}"; do
        if [[ "$leaf" == "$alias_name" ]]; then
          alias_var="_CONFIG_LEGACY_ALIAS_VAR_${alias_name}"
          alias_var="${!alias_var}"
          if [[ -n "${!alias_var:-}" ]]; then
            value="${!alias_var}"
            origin="env"
            detail="$alias_var"
          fi
          break
        fi
      done
    fi
  fi

  # 3. config file
  if [[ -z "$origin" ]] && _config__is_set "_CONFIG_FILE_VALUE__${key}"; then
    local file_value
    file_value="$(_config__var "_CONFIG_FILE_VALUE__${key}")"
    if [[ -n "$file_value" && "$file_value" != "null" ]]; then
      value="$file_value"
      origin="file"
      detail="${CONFIG_FILE_DISPLAY_PATH}"
    fi
  fi

  # 4. template default (optional fields only — a required field has none)
  if [[ -z "$origin" && "$required" != "true" ]]; then
    local default_value=""
    if [[ "$(_config__var "_CONFIG_TPL_HASDEFAULT__${key}" || printf '0')" == "1" ]]; then
      default_value="$(_config__var "_CONFIG_TPL_DEFAULT__${key}")"
    elif _config__is_set "_CONFIG_TPL_VALUE__${key}"; then
      default_value="$(_config__var "_CONFIG_TPL_VALUE__${key}")"
    fi
    if [[ -n "$default_value" ]]; then
      value="$default_value"
      origin="default"
      detail="template"
    fi
  fi

  # 5. nothing supplied the value
  if [[ -z "$origin" ]]; then
    _CONFIG_RESOLVED_VALUE=""
    _CONFIG_RESOLVED_ORIGIN="MISSING"
    _CONFIG_RESOLVED_ORIGIN_DETAIL=""
    _config__set "_CONFIG_ORIGIN__${key}" "MISSING"
    _config__set "_CONFIG_ORIGIN_DETAIL__${key}" ""
    if [[ "$soft" == "1" ]]; then
      return 1
    fi
    _config__die "required config field '${path}' is not set" \
      "Set it in ${CONFIG_FILE_DISPLAY_PATH}, export $(_config__env_name "$path"), or run scripts/setup-config.sh."
  fi

  # placeholder guard — a value that is still a placeholder is never usable
  if [[ "$origin" != "default" ]] && config::is_placeholder "$path" "$value"; then
    _CONFIG_RESOLVED_VALUE="$value"
    _CONFIG_RESOLVED_ORIGIN="PLACEHOLDER"
    _CONFIG_RESOLVED_ORIGIN_DETAIL="$detail"
    _config__set "_CONFIG_ORIGIN__${key}" "PLACEHOLDER"
    _config__set "_CONFIG_ORIGIN_DETAIL__${key}" "$detail"
    if [[ "$soft" == "1" ]]; then
      return 1
    fi
    _config__die "config field '${path}' still holds the placeholder value '${value}'" \
      "Replace it in ${CONFIG_FILE_DISPLAY_PATH} with the value for your own account." \
      "scripts/setup-config.sh prompts for every field the template declares."
  fi

  # format / enum guard — the declared shape applies to a value from any source
  # (flag, env, config file), so a hand-edited config is held to the same rules
  # the Setup_Wizard applies at entry time.  A template default is trusted, for
  # the same reason the placeholder guard above skips defaults.
  if [[ "$origin" != "default" ]] && ! _config__validate "$path" "$value"; then
    _CONFIG_RESOLVED_VALUE="$value"
    _CONFIG_RESOLVED_ORIGIN="INVALID"
    _CONFIG_RESOLVED_ORIGIN_DETAIL="$detail"
    _config__set "_CONFIG_ORIGIN__${key}" "INVALID"
    _config__set "_CONFIG_ORIGIN_DETAIL__${key}" "$detail"
    if [[ "$soft" == "1" ]]; then
      return 1
    fi
    _config__die "config field '${path}' has an invalid value '${value}' (from ${detail})" \
      "${_CONFIG_VALIDATION_HINT}" \
      "Fix it in ${CONFIG_FILE_DISPLAY_PATH}; ${CONFIG_TEMPLATE_DISPLAY_PATH} declares the field's format." \
      "scripts/setup-config.sh validates every value as it prompts for it."
  fi

  _config__set "_CONFIG_VALUE__${key}" "$value"
  _config__set "_CONFIG_ORIGIN__${key}" "$origin"
  _config__set "_CONFIG_ORIGIN_DETAIL__${key}" "$detail"
  _CONFIG_RESOLVED_VALUE="$value"
  _CONFIG_RESOLVED_ORIGIN="$origin"
  _CONFIG_RESOLVED_ORIGIN_DETAIL="$detail"
  return 0
}

_config__role_prefix() {
  case "$1" in
    be)  printf 'backend' ;;
    fe)  printf 'frontend' ;;
    ops) printf 'ops' ;;
    *)
      _config__die "unknown account role '${1}'" \
        "Expected one of: be, fe, ops."
      ;;
  esac
}

# ─── Public interface ────────────────────────────────────────────────────────

# config::init [--config PATH] [--template PATH]
#
# Verifies prerequisites, locates the config file and the template, and loads
# both.  Exits non-zero on missing jq (R3.4) or a missing config file (R3.1).
# AIOPS_CONFIG_FILE / AIOPS_CONFIG_TEMPLATE override the derived locations.
config::init() {
  local config_flag="" template_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)   config_flag="${2:-}"; shift 2 ;;
      --template) template_flag="${2:-}"; shift 2 ;;
      *)
        _config__die "config::init: unknown argument '${1}'" \
          "Usage: config::init [--config PATH] [--template PATH]"
        ;;
    esac
  done

  # jq is checked first, before anything external is invoked, so that a machine
  # without jq gets the jq message and not a confusing secondary failure.
  if ! command -v jq >/dev/null 2>&1; then
    _config__die "'jq' is required but was not found on PATH" \
      "Install jq (for example: brew install jq) and re-run." \
      "Every script in this repository reads config/accounts.json with jq."
  fi

  local lib_dir root_dir
  lib_dir="${BASH_SOURCE[0]%/*}"
  lib_dir="$(cd "$lib_dir" && pwd)"
  root_dir="$(cd "${lib_dir}/../.." && pwd)"
  CONFIG_PROJECT_ROOT="$root_dir"

  if [[ -n "$config_flag" ]]; then
    CONFIG_FILE_PATH="$config_flag"
  else
    CONFIG_FILE_PATH="${AIOPS_CONFIG_FILE:-${root_dir}/config/accounts.json}"
  fi
  if [[ -n "$template_flag" ]]; then
    CONFIG_TEMPLATE_PATH="$template_flag"
  else
    CONFIG_TEMPLATE_PATH="${AIOPS_CONFIG_TEMPLATE:-${CONFIG_FILE_PATH}.template}"
  fi

  # Display paths stay repo-relative so diagnostics read the way the docs do.
  CONFIG_FILE_DISPLAY_PATH="${CONFIG_FILE_PATH#${root_dir}/}"
  CONFIG_TEMPLATE_DISPLAY_PATH="${CONFIG_TEMPLATE_PATH#${root_dir}/}"

  if [[ ! -f "${CONFIG_TEMPLATE_PATH}" ]]; then
    _config__die "the parameter template ${CONFIG_TEMPLATE_DISPLAY_PATH} is missing" \
      "It is committed to the repository and declares every configurable field." \
      "Restore it with: git checkout -- ${CONFIG_TEMPLATE_DISPLAY_PATH}"
  fi

  if [[ ! -f "${CONFIG_FILE_PATH}" ]]; then
    _config__die "the configuration file ${CONFIG_FILE_DISPLAY_PATH} is missing" \
      "Run scripts/setup-config.sh to be prompted for every value, or copy the template:" \
      "  cp ${CONFIG_TEMPLATE_DISPLAY_PATH} ${CONFIG_FILE_DISPLAY_PATH}" \
      "then edit ${CONFIG_FILE_DISPLAY_PATH} — it is git-ignored and is the only file you edit."
  fi

  _config__load_template
  _config__load_config_file
  _CONFIG_INITIALIZED=1
}

# config::use_legacy_aliases
#
# Per-script opt-in to the bare PROFILE / REGION environment names enumerated
# at the top of this file.  Call it after config::init.  No script in this
# repository opts in — the pre-refactor scripts all cleared PROFILE / REGION
# before use, so the aliases would be a new override path, not a preserved one.
config::use_legacy_aliases() {
  _CONFIG_LEGACY_ENABLED=1
}

# config::resolve <json.path> [flag_value]
#
# Resolves and records one input in the caller's shell, printing nothing.  Use
# it when a flag value participates and the origin must remain reportable:
#
#   config::resolve ops.region "${REGION_FLAG:-}"
#   REGION="$(config::get ops.region)"      # replays the record
#   config::origin ops.region               # -> flag (command line)
config::resolve() {
  _config__ensure_init
  if [[ $# -lt 1 || -z "${1:-}" ]]; then
    _config__die "config::resolve requires a JSON path" \
      "Usage: config::resolve <json.path> [flag_value]"
  fi
  _config__resolve "$1" "${2:-}" 0
}

# config::get <json.path> [flag_value]
#
# Prints the resolved value on stdout.  An empty flag_value means "no flag was
# supplied", which keeps call sites free of conditionals.
config::get() {
  _config__ensure_init
  if [[ $# -lt 1 || -z "${1:-}" ]]; then
    _config__die "config::get requires a JSON path" \
      "Usage: config::get <json.path> [flag_value]"
  fi
  _config__resolve "$1" "${2:-}" 0
  printf '%s\n' "${_CONFIG_RESOLVED_VALUE}"
}

# config::origin_level <json.path>  -> flag | env | file | default
config::origin_level() {
  _config__ensure_init
  local key origin
  key="$(_config__key "$1")"
  if ! origin="$(_config__var "_CONFIG_ORIGIN__${key}")"; then
    _config__resolve "$1" "" 0
    origin="${_CONFIG_RESOLVED_ORIGIN}"
  fi
  printf '%s\n' "$origin"
}

# config::origin <json.path>  -> "env (AIOPS_OPS_REGION)", "default (template)", …
#
# The precedence level, with the detail that supplied the value in parentheses.
# The level alone is available from config::origin_level.
config::origin() {
  _config__ensure_init
  local key origin detail
  key="$(_config__key "$1")"
  if ! origin="$(_config__var "_CONFIG_ORIGIN__${key}")"; then
    _config__resolve "$1" "" 0
    origin="${_CONFIG_RESOLVED_ORIGIN}"
  fi
  detail="$(_config__var "_CONFIG_ORIGIN_DETAIL__${key}" || printf '')"
  if [[ -n "$detail" ]]; then
    printf '%s (%s)\n' "$origin" "$detail"
  else
    printf '%s\n' "$origin"
  fi
}

# config::account <be|fe|ops> [--profile-flag V] [--region-flag V]
#
# Resolves the {accountId, region, profile} triple for one role and exports
# CONFIG_<ROLE>_ACCOUNT, CONFIG_<ROLE>_REGION and CONFIG_<ROLE>_PROFILE.
# Silent on success; every diagnostic goes to stderr.
config::account() {
  _config__ensure_init
  local role="${1:-}"
  shift || true
  local prefix
  prefix="$(_config__role_prefix "$role")"

  local profile_flag="" region_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile-flag) profile_flag="${2:-}"; shift 2 ;;
      --region-flag)  region_flag="${2:-}";  shift 2 ;;
      *)
        _config__die "config::account: unknown argument '${1}'" \
          "Usage: config::account <be|fe|ops> [--profile-flag V] [--region-flag V]"
        ;;
    esac
  done

  local role_uc
  role_uc="$(printf '%s' "$role" | tr 'a-z' 'A-Z')"

  _config__resolve "${prefix}.accountId" "" 0
  _config__set "CONFIG_${role_uc}_ACCOUNT" "${_CONFIG_RESOLVED_VALUE}"
  _config__resolve "${prefix}.region" "$region_flag" 0
  _config__set "CONFIG_${role_uc}_REGION" "${_CONFIG_RESOLVED_VALUE}"
  _config__resolve "${prefix}.profile" "$profile_flag" 0
  _config__set "CONFIG_${role_uc}_PROFILE" "${_CONFIG_RESOLVED_VALUE}"

  export "CONFIG_${role_uc}_ACCOUNT" "CONFIG_${role_uc}_REGION" "CONFIG_${role_uc}_PROFILE"
}

# config::is_placeholder <json.path> <value>
#
# True (exit 0) when the value is visibly not a real one: a canonical
# placeholder account ID, a REPLACE_WITH_ / your- prefixed string, or the
# template's own value for a field whose format cannot legitimately be shared
# between the template and a real configuration (accountId, email).
config::is_placeholder() {
  local path="${1:-}"
  local value="${2:-}"
  [[ -z "$value" ]] && return 1

  if [[ "$value" =~ ${_CONFIG_PLACEHOLDER_ID_RE} ]]; then
    return 0
  fi
  if [[ "$value" =~ ${_CONFIG_PLACEHOLDER_PREFIX_RE} ]]; then
    return 0
  fi

  if [[ -n "$path" && "${_CONFIG_INITIALIZED}" == "1" ]]; then
    local key format tpl_value
    key="$(_config__key "$path")"
    format="$(_config__var "_CONFIG_TPL_FORMAT__${key}" || printf 'string')"
    if _config__template_equality_applies "$format" \
      && tpl_value="$(_config__var "_CONFIG_TPL_VALUE__${key}")" \
      && [[ -n "$tpl_value" && "$value" == "$tpl_value" ]]; then
      return 0
    fi
  fi
  return 1
}

# config::dump [--redact]
#
# One row per declared field: JSON path, resolved value, origin.  Missing,
# invalid and placeholder-valued fields are reported rather than fatal, so a
# caller can list every problem at once; the exit status is non-zero when any
# row failed.
# With --redact, account identifiers print as their last four digits.
config::dump() {
  _config__ensure_init
  local redact=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --redact) redact=1; shift ;;
      *)
        _config__die "config::dump: unknown argument '${1}'" \
          "Usage: config::dump [--redact]"
        ;;
    esac
  done

  local failures=0 path key format value origin display
  printf '%-34s %-46s %s\n' "JSON PATH" "VALUE" "ORIGIN"
  printf '%-34s %-46s %s\n' "---------" "-----" "------"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    key="$(_config__key "$path")"
    format="$(_config__var "_CONFIG_TPL_FORMAT__${key}" || printf 'string')"
    if _config__resolve "$path" "" 1; then
      value="${_CONFIG_RESOLVED_VALUE}"
      origin="${_CONFIG_RESOLVED_ORIGIN}"
      if [[ -n "${_CONFIG_RESOLVED_ORIGIN_DETAIL}" ]]; then
        origin="${origin} (${_CONFIG_RESOLVED_ORIGIN_DETAIL})"
      fi
    else
      failures=$((failures + 1))
      value="${_CONFIG_RESOLVED_VALUE}"
      origin="${_CONFIG_RESOLVED_ORIGIN}"
    fi
    display="$value"
    if [[ "$redact" == "1" && "$format" == "accountId" && ${#value} -eq 12 ]]; then
      display="********${value: -4}"
    fi
    printf '%-34s %-46s %s\n' "$path" "$display" "$origin"
  done <<< "${_CONFIG_DECLARED_PATHS}"

  if [[ "$failures" -gt 0 ]]; then
    printf '%s\n' "${failures} configuration field(s) are missing, invalid, or still hold a placeholder value." >&2
    return 1
  fi
  return 0
}

# config::aws <be|fe|ops> [--] <aws args...>
#
# Runs the AWS CLI against one account with the profile and region resolved for
# that account, so no call site restates either (Requirement 2.4).
config::aws() {
  _config__ensure_init
  local role="${1:-}"
  shift || true
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  local prefix role_uc profile_var region_var
  prefix="$(_config__role_prefix "$role")"
  role_uc="$(printf '%s' "$role" | tr 'a-z' 'A-Z')"
  profile_var="CONFIG_${role_uc}_PROFILE"
  region_var="CONFIG_${role_uc}_REGION"
  if ! _config__is_set "$profile_var" || ! _config__is_set "$region_var"; then
    config::account "$role"
  fi
  if [[ $# -eq 0 ]]; then
    _config__die "config::aws requires AWS CLI arguments" \
      "Usage: config::aws <be|fe|ops> [--] <aws args...>"
  fi
  aws --profile "${!profile_var}" --region "${!region_var}" "$@"
}
