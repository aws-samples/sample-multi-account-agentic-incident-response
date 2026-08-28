#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/setup-config.sh — Setup_Wizard
#
# The first setup step: it asks for every value a Replicator must supply and
# writes config/accounts.json, so nobody has to hand-edit JSON to deploy this
# PoC. Hand-editing stays supported (docs/deployment.md keeps the `cp` path) —
# this is a convenience, not a gate.
#
#   scripts/setup-config.sh                       # prompt for required inputs
#   scripts/setup-config.sh --include-optional    # prompt for everything
#   scripts/setup-config.sh --force --no-verify   # overwrite, stay offline
#   scripts/setup-config.sh --non-interactive --set backend.accountId=… …
#
# THE PROMPT SET IS NOT WRITTEN DOWN HERE. Every field, its description, its
# required/optional status, its default, its format and its allowed values come
# from the _doc block of config/accounts.json.template, read at runtime in
# template order. A field added to the template is prompted for by this script
# without a line of it changing (Requirement 11.2), and the same is true of the
# three account entries the region-agreement and verification steps work on:
# they are the fields the template declares with format `accountId`, not a list
# of role names typed in here.
#
# What it never does:
#   * prompt for an Upstream_Fixed_Name — those are fixed by the pinned upstream
#     sample and hardcoded where they are consumed, so offering a prompt
#     would only invite a wrong answer (decision D9);
#   * write a Replicator's account identifier anywhere other than
#     config/accounts.json — no log, no backup, no unredacted table (R11.21);
#   * make a mutating AWS call. The only call it ever makes is
#     `aws sts get-caller-identity`, and --no-verify skips even that (R11.16/17).
#     It is memoized per profile, because two things now read it: the per-account
#     verification, and the session-name default offered for a field the template
#     declares with `sessionNameFrom` (today that is
#     operator.federationIdentifier, whose value is the session name of the
#     principal that will sign in to the Operator Web App — the one required
#     input a Replicator cannot read off anything they already have, unless the
#     wizard reads it for them).
#
# Validation, placeholder detection and the final verdict are all borrowed
# rather than reimplemented: the placeholder rule and the format/enum rules come
# from scripts/lib/config.sh (the same code the deploy path uses, so a value
# this wizard accepts is a value the resolver accepts), and the closing verdict
# is `exec scripts/preflight.sh` (R11.20) so there is exactly one definition of
# "this configuration is ready".
#
# Requirements: 11.1-11.21, 1.6
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

FORCE=0
NO_VERIFY=0
INCLUDE_OPTIONAL=0
NON_INTERACTIVE=0
SHOW_IDS=0
assignment=""

# --set values, stored as dynamic variables (bash 3.2 has no associative
# arrays — this is the printf -v + indirect expansion idiom scripts/lib/config.sh
# established).
SET_PATHS=()

usage() {
  cat <<'EOF'
Usage: scripts/setup-config.sh [options]

Prompts for every input config/accounts.json.template declares as required and
writes config/accounts.json. Values a deploy produces are not asked for; see
docs/parameters.md.

  --force               Overwrite an existing config/accounts.json without asking
  --no-verify           Make no AWS calls at all
  --include-optional    Prompt for optional fields too (default: keep their
                        current value, or the template default)
  --non-interactive     Never prompt; take every value from --set or the
                        canonical AIOPS_* environment variables
  --set <path>=<value>  Supply one input by JSON path (repeatable). In
                        interactive mode it pre-fills that prompt. Note that
                        flags land in your shell history.
  --show-ids            Print account identifiers in full instead of their last
                        four digits
  -h, --help            Show this help

Value precedence, non-interactive:  --set > AIOPS_* env > existing config file >
template default (optional fields only). A required input with no value exits
non-zero naming its JSON path.

Default offered at each prompt:  --set > the existing non-placeholder value in
config/accounts.json > the template default > none. For a field the template
declares with sessionNameFrom (operator.federationIdentifier), the last resort
before "none" is the session name the named profile is presenting, parsed from
`aws sts get-caller-identity --query Arn`; the prompt says where it came from,
and says why when there is none to offer. --no-verify skips that lookup with
everything else.

Exit status: whatever scripts/preflight.sh returns once the file is written; 1
on a rejected value or a declined overwrite; 2 on a usage error.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --no-verify) NO_VERIFY=1 ;;
    --include-optional) INCLUDE_OPTIONAL=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --show-ids) SHOW_IDS=1 ;;
    --set | --set=*)
      if [[ "$1" == "--set" ]]; then
        shift
        assignment="${1:-}"
      else
        assignment="${1#--set=}"
      fi
      if [[ "${assignment}" != *=* || -z "${assignment%%=*}" ]]; then
        printf 'setup-config: --set needs <json.path>=<value>\n' >&2
        exit 2
      fi
      SET_PATHS+=("${assignment%%=*}")
      printf -v "WIZ_SET__$(printf '%s' "${assignment%%=*}" | tr -c 'A-Za-z0-9' '_')" \
        '%s' "${assignment#*=}"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'setup-config: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

die() {
  printf '\nsetup-config: %s\n' "$1" >&2
  shift
  while [[ $# -gt 0 ]]; do
    printf '  %s\n' "$1" >&2
    shift
  done
  exit 1
}

# ─── The shared resolver ─────────────────────────────────────────────────────
#
# Sourced for two things, both of which must stay identical to the deploy path:
# config::is_placeholder (R11.10) and the format/enum rules the resolver applies
# to a hand-edited file. Copying either rule here is how a wizard starts
# accepting values the deploy then rejects.
#
# config::init insists on an existing configuration file, which the wizard by
# definition may not have yet, so on a first run the template stands in as the
# "current" file. Nothing is read back through the resolver — existing values
# are read straight from the target file below — the init call is there to load
# the template's declarations and to fail early, and loudly, on a missing jq or
# a missing template.

CONFIG_LIB="${SCRIPT_DIR}/lib/config.sh"
if [[ ! -f "${CONFIG_LIB}" ]]; then
  printf 'setup-config: the Config_Resolver is missing at scripts/lib/config.sh\n' >&2
  printf '  restore it with: git checkout -- scripts/lib/config.sh\n' >&2
  exit 2
fi

TARGET="${AIOPS_CONFIG_FILE:-${PROJECT_ROOT}/config/accounts.json}"
TPL="${AIOPS_CONFIG_TEMPLATE:-${TARGET}.template}"
TARGET_DISPLAY="${TARGET#"${PROJECT_ROOT}"/}"
TPL_DISPLAY="${TPL#"${PROJECT_ROOT}"/}"
TARGET_EXISTS=0
[[ -f "${TARGET}" ]] && TARGET_EXISTS=1

# shellcheck source=scripts/lib/config.sh
source "${CONFIG_LIB}"
if [[ "${TARGET_EXISTS}" -eq 1 ]]; then
  config::init --config "${TARGET}" --template "${TPL}"
else
  config::init --config "${TPL}" --template "${TPL}"
fi

# ─── Field metadata, read from the template ──────────────────────────────────

WIZ_FS=$'\x1f'
WIZ_RS=$'\x1e'

ORDERED_PATHS=()

wiz_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

wiz_meta() {
  local name="WIZ_${1}__$(wiz_key "$2")"
  printf '%s' "${!name:-}"
}

wiz_set_meta() { printf -v "WIZ_${1}__$(wiz_key "$2")" '%s' "$3"; }

wiz_value() {
  local name="WIZ_VALUE__$(wiz_key "$1")"
  printf '%s' "${!name:-}"
}

wiz_set_value() { printf -v "WIZ_VALUE__$(wiz_key "$1")" '%s' "$2"; }

wiz_supplied() {
  local name="WIZ_SET__$(wiz_key "$1")"
  printf '%s' "${!name:-}"
}

wiz_has_supplied() {
  local name="WIZ_SET__$(wiz_key "$1")"
  [[ -n "${!name+x}" ]]
}

load_declarations() {
  local path required has_default default format allowed description consumers
  local session_from doc
  doc="$(jq -r '
    (._doc // {})
    | to_entries[]
    | select(.value | type == "object")
    | .key + "\u001f"
      + ((.value.required // false) | tostring) + "\u001f"
      + (if (.value | has("default")) then "1" else "0" end) + "\u001f"
      + (if (.value | has("default")) then (.value.default | tostring) else "" end) + "\u001f"
      + (.value.format // "string") + "\u001f"
      + ((.value.allowed // []) | map(tostring) | join("\u001e")) + "\u001f"
      + ((.value.description // "") | gsub("[\n\r]"; " ")) + "\u001f"
      + ((.value.consumedBy // []) | map(tostring) | join("\u001e")) + "\u001f"
      + (.value.sessionNameFrom // "")
  ' "${TPL}")" || die "could not read the field declarations from ${TPL_DISPLAY}" \
    "The template must be valid JSON with a _doc block. Restore it with:" \
    "  git checkout -- ${TPL_DISPLAY}"

  while IFS="${WIZ_FS}" read -r path required has_default default format allowed description consumers session_from; do
    [[ -n "$path" ]] && [[ "$path" != '$' ]] || continue
    ORDERED_PATHS+=("$path")
    wiz_set_meta DECLARED "$path" 1
    wiz_set_meta REQUIRED "$path" "$required"
    wiz_set_meta HASDEFAULT "$path" "$has_default"
    wiz_set_meta DEFAULT "$path" "$default"
    wiz_set_meta FORMAT "$path" "$format"
    wiz_set_meta ALLOWED "$path" "$allowed"
    wiz_set_meta DESC "$path" "$description"
    wiz_set_meta CONSUMERS "$path" "$consumers"
    wiz_set_meta SESSIONFROM "$path" "$session_from"
  done <<< "$doc"

  if [[ "${#ORDERED_PATHS[@]}" -eq 0 ]]; then
    die "${TPL_DISPLAY} declares no fields, so there is nothing to ask for" \
      "Every field is declared in the template's _doc block; see docs/parameters.md."
  fi
}

load_declarations

# Every --set path must be a field the template declares — a typo in an
# automation script should be a loud failure, not a silently ignored value.
for supplied_path in "${SET_PATHS[@]:-}"; do
  [[ -n "${supplied_path}" ]] || continue
  if [[ "$(wiz_meta DECLARED "${supplied_path}")" != "1" ]]; then
    die "--set names '${supplied_path}', which ${TPL_DISPLAY} does not declare" \
      "Run scripts/setup-config.sh --help, or read the _doc block of ${TPL_DISPLAY} for the field list."
  fi
done

# ─── Presentation ────────────────────────────────────────────────────────────

redact_id() {
  local value="$1"
  if [[ "${SHOW_IDS}" -eq 1 || ${#value} -ne 12 ]]; then
    printf '%s' "${value}"
  else
    printf '********%s' "${value: -4}"
  fi
}

# Account identifiers are shown by their last four digits everywhere the wizard
# prints, so a scrollback or a pasted transcript leaks nothing (R11.21 is about
# files; this is the same instinct applied to the terminal).
display_value() {
  local path="$1" value="$2"
  if [[ "$(wiz_meta FORMAT "$path")" == "accountId" ]]; then
    redact_id "$value"
  else
    printf '%s' "$value"
  fi
}

wrap() {
  local indent="$1" text="$2"
  [[ -n "$text" ]] || return 0
  printf '%s\n' "$text" | fold -s -w 72 | sed "s/^/${indent}/"
}

allowed_list() {
  local allowed
  allowed="$(wiz_meta ALLOWED "$1")"
  [[ -n "$allowed" ]] || return 1
  printf '%s' "$allowed" | tr "${WIZ_RS}" ',' | sed 's/,/, /g'
}

consumer_summary() {
  local consumers count first
  consumers="$(wiz_meta CONSUMERS "$1")"
  [[ -n "$consumers" ]] || return 1
  count="$(printf '%s' "$consumers" | tr "${WIZ_RS}" '\n' | grep -c . || true)"
  first="$(printf '%s' "$consumers" | tr "${WIZ_RS}" '\n' | head -n 2 | tr '\n' ',' \
    | sed 's/,$//; s/,/, /g')"
  if [[ "$count" -gt 2 ]]; then
    printf '%s (+%d more)' "$first" "$((count - 2))"
  else
    printf '%s' "$first"
  fi
}

trim() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s' "$text"
}

# ─── Value sources ───────────────────────────────────────────────────────────

# The value already in the target file, when it is there and is not a
# placeholder (R11.8). This is what turns a re-run into an edit/repair flow:
# pressing Enter through the wizard keeps the configuration exactly as it was.
existing_value() {
  local path="$1" value
  [[ "${TARGET_EXISTS}" -eq 1 ]] || return 1
  value="$(jq -r --arg p "$path" '
      ($p | split(".")) as $k
      | getpath($k)
      | if . == null then empty else tostring end
    ' "${TARGET}" 2>/dev/null)" || return 1
  [[ -n "$value" ]] || return 1
  config::is_placeholder "$path" "$value" && return 1
  printf '%s' "$value"
}

template_default() {
  local path="$1"
  if [[ "$(wiz_meta HASDEFAULT "$path")" == "1" ]]; then
    printf '%s' "$(wiz_meta DEFAULT "$path")"
    return 0
  fi
  return 1
}

env_value() {
  local name
  name="$(_config__env_name "$1")"
  [[ -n "${!name:-}" ]] || return 1
  printf '%s' "${!name}"
}

# ─── Caller identity, fetched at most once per profile ───────────────────────
#
# Two things want it now: the per-account verification at the end, and the
# session-name default offered for a field the template declares with
# `sessionNameFrom`. A second call per profile would break the contract stated at
# the top of this script — get-caller-identity is the *only* AWS call it makes,
# and --no-verify makes none at all (R11.16, R11.17) — so both read through this
# memo and a profile is contacted once or not at all.
#
# Three dynamic variables per profile rather than one associative array (bash
# 3.2): the JSON on success, the first line of the failure otherwise, and an
# attempted flag so a failure is reported the same way everywhere instead of
# being retried.

sts_var() { printf '%s' "WIZ_STS_$1__$(wiz_key "$2")"; }

STS_IDENTITY_JSON=""

# sts_identity <profile> <region> — leaves the identity document in
# STS_IDENTITY_JSON and returns non-zero when there is none (sts_failure then
# says why).
#
# It reports through a global instead of stdout deliberately: a caller writing
# `x="$(sts_identity …)"` would run it in a subshell, and the memo written there
# would die with the subshell — which is precisely how a call-once memo becomes
# one call per caller. Every caller therefore invokes it as a statement.
sts_identity() {
  local profile="$1" region="$2"
  local done_var json_var err_var out
  done_var="$(sts_var DONE "$profile")"
  json_var="$(sts_var JSON "$profile")"
  err_var="$(sts_var ERR "$profile")"

  if [[ -z "${!done_var:-}" ]]; then
    printf -v "${done_var}" '%s' 1
    printf -v "${json_var}" '%s' ''
    printf -v "${err_var}" '%s' ''
    if [[ -z "$profile" ]]; then
      printf -v "${err_var}" '%s' 'no CLI profile is set for that account entry'
    elif [[ "${NO_VERIFY}" -eq 1 ]]; then
      printf -v "${err_var}" '%s' '--no-verify was passed, so no AWS call was made'
    elif ! command -v aws >/dev/null 2>&1; then
      printf -v "${err_var}" '%s' 'the AWS CLI is not on PATH'
    else
      if [[ -n "$region" ]]; then
        out="$(aws sts get-caller-identity --profile "${profile}" --region "${region}" --output json 2>&1)" \
          && printf -v "${json_var}" '%s' "$out" \
          || printf -v "${err_var}" '%s' "$(printf '%s' "$out" | head -n 1)"
      else
        out="$(aws sts get-caller-identity --profile "${profile}" --output json 2>&1)" \
          && printf -v "${json_var}" '%s' "$out" \
          || printf -v "${err_var}" '%s' "$(printf '%s' "$out" | head -n 1)"
      fi
    fi
  fi

  STS_IDENTITY_JSON="${!json_var:-}"
  [[ -n "${STS_IDENTITY_JSON}" ]]
}

sts_failure() {
  local name
  name="$(sts_var ERR "$1")"
  printf '%s' "${!name:-}"
}

# session_name_from_arn <arn>
#
# The session name is the last slash-delimited segment of an assumed-role ARN:
#
#   arn:aws:sts::<account>:assumed-role/<role-name>/<session-name>
#
# Any other principal shape — an IAM user, the account root, an ARN this does not
# recognise — has no session name in it, and offering a confidently wrong default
# is the exact failure this is here to prevent, so those return non-zero and the
# caller falls back to prompting with no default.
session_name_from_arn() {
  local arn="$1" resource session
  case "$arn" in
    arn:*:sts:*:assumed-role/*/*) ;;
    *) return 1 ;;
  esac
  resource="${arn#*:assumed-role/}"
  session="${resource##*/}"
  [[ -n "$session" ]] || return 1
  [[ "$session" != "$resource" ]] || return 1
  printf '%s' "$session"
}

WIZ_DERIVED_DEFAULT=""

# derived_session_name <json.path> — the session name the profile that field
# points at is currently presenting, left in WIZ_DERIVED_DEFAULT.
#
# Reports through a global for the same reason sts_identity does: it has to run
# in the wizard's own shell for the one-call-per-profile memo to hold.
#
# Deliberately interactive-only (see prompt_field): in --non-interactive mode a
# derived value would mean the wizard inventing a required input nobody supplied,
# which is the opposite of R11.19's "name the JSON path and stop".
derived_session_name() {
  local path="$1" source_path prefix profile region arn
  WIZ_DERIVED_DEFAULT=""
  source_path="$(wiz_meta SESSIONFROM "$path")"
  [[ -n "$source_path" ]] || return 1
  [[ "$(wiz_meta DECLARED "$source_path")" == "1" ]] || return 1

  profile="$(wiz_value "$source_path")"
  [[ -n "$profile" ]] || profile="$(current_default "$source_path")" || return 1

  region=""
  case "$source_path" in
    *.*)
      prefix="${source_path%.*}"
      region="$(wiz_value "${prefix}.region")"
      [[ -n "$region" ]] || region="$(current_default "${prefix}.region")" || region=""
      ;;
  esac

  sts_identity "$profile" "$region" || return 1
  arn="$(printf '%s' "${STS_IDENTITY_JSON}" | jq -r '.Arn // empty' 2>/dev/null)"
  [[ -n "$arn" ]] || return 1
  WIZ_DERIVED_DEFAULT="$(session_name_from_arn "$arn")" || return 1
  [[ -n "${WIZ_DERIVED_DEFAULT}" ]]
}

# The default a prompt offers, and — for an optional field nobody is prompted
# about — the value written. Keeping those the same is what makes a run without
# --include-optional preserve an optional value the Replicator had already
# tuned, instead of quietly resetting it to the template default.
current_default() {
  local path="$1" value
  if wiz_has_supplied "$path"; then
    value="$(wiz_supplied "$path")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  if value="$(existing_value "$path")"; then
    printf '%s' "$value"
    return 0
  fi
  if value="$(template_default "$path")"; then
    printf '%s' "$value"
    return 0
  fi
  return 1
}

# ─── Validation ──────────────────────────────────────────────────────────────
#
# Both rules come from the resolver: config::is_placeholder for R11.10, and
# _config__validate for the accountId / email / boolean / enum rules of R11.9,
# R11.12 and R11.13. The wizard holds no pattern of its own, so it cannot drift
# from what the deploy path will accept — which is the failure this borrowing
# is here to prevent.

WIZ_REJECTION=""

validate_value() {
  local path="$1" value="$2"
  WIZ_REJECTION=""

  if [[ -z "$(trim "$value")" ]]; then
    WIZ_REJECTION="a value is required — there is no default for this field."
    return 1
  fi

  if config::is_placeholder "$path" "$value"; then
    WIZ_REJECTION="that is the template's placeholder value, not a real one — enter the value for your own account."
    return 1
  fi

  if ! _config__validate "$path" "$value"; then
    WIZ_REJECTION="${_CONFIG_VALIDATION_HINT}"
    return 1
  fi

  return 0
}

# ─── Prompting ───────────────────────────────────────────────────────────────

PROMPT_INDEX=0
PROMPT_TOTAL=0

show_field() {
  local path="$1" desc allowed consumers
  desc="$(wiz_meta DESC "$path")"
  printf '\n'
  if [[ "${PROMPT_TOTAL}" -gt 0 ]]; then
    printf '[%d/%d] %s\n' "${PROMPT_INDEX}" "${PROMPT_TOTAL}" "$path"
  else
    printf '%s\n' "$path"
  fi
  wrap '      ' "$desc"
  if allowed="$(allowed_list "$path")"; then
    printf '      allowed: %s\n' "$allowed"
  fi
  if consumers="$(consumer_summary "$path")"; then
    wrap '      used by: ' "$consumers"
  fi
}

# session_name_note <json.path> <derived|configured|none>
#
# Says where a derived default came from, or — and this is the half that matters —
# why none is offered. A profile that authenticates as an IAM user or as the
# account root has no session name to read, and neither does a run that made no
# AWS call at all; in either case the Replicator has to know the wizard has
# nothing for them rather than wonder why the prompt looks bare. A default that
# came from the existing configuration or from --set needs no commentary.
#
# The reason is stated in words. It deliberately does not echo the caller ARN,
# which carries an account identifier the rest of this script is careful to keep
# out of terminal scrollback.
session_name_note() {
  local path="$1" origin="$2" source_path profile reason
  source_path="$(wiz_meta SESSIONFROM "$path")"
  [[ -n "$source_path" ]] || return 0
  [[ "$origin" != "configured" ]] || return 0

  profile="$(wiz_value "$source_path")"
  [[ -n "$profile" ]] || profile="$(current_default "$source_path")" || profile=""

  if [[ "$origin" == "derived" ]]; then
    printf '      offered: the session name profile %s is presenting now, read from\n' \
      "${profile:-<unset>}"
    printf '               aws sts get-caller-identity --query Arn (assumed-role/<role>/<session-name>).\n'
    printf '               Enter a different identity if someone else will sign in to the web app.\n'
    return 0
  fi

  reason="$(sts_failure "$profile")"
  if [[ -z "$reason" ]]; then
    reason="profile ${profile:-<unset>} is not authenticating through an assumed role, so its credentials carry no session name"
  fi
  wrap '      no default: ' "${reason} — enter the session name the identity you will sign in to the web app with presents."
}

# prompt_field <json.path> [--renumber]
# Shows the description and the JSON path (R11.3), offers a default (R11.4,
# R11.8), and re-prompts on every rejection reporting the expected form
# (R11.9-11.13).
prompt_field() {
  local path="$1"
  local default_value="" has_default=0 origin="none" reply shown

  if default_value="$(current_default "$path")"; then
    has_default=1
    origin="configured"
  elif derived_session_name "$path"; then
    # Nothing configured yet, and the template says this field holds the session
    # name of a principal the wizard can look up: offer what that profile is
    # presenting right now instead of leaving a Replicator to guess. Called as a
    # statement, not in a command substitution, so the identity it reads is
    # memoized for the verification step (R11.16).
    default_value="${WIZ_DERIVED_DEFAULT}"
    has_default=1
    origin="derived"
  fi

  PROMPT_INDEX=$((PROMPT_INDEX + 1))
  show_field "$path"
  session_name_note "$path" "${origin}"

  while :; do
    if [[ "${has_default}" -eq 1 ]]; then
      shown="$(display_value "$path" "$default_value")"
      printf '      value [%s]: ' "$shown"
    else
      printf '      value: '
    fi

    if ! IFS= read -r reply; then
      printf '\n'
      die "no answer was given for '${path}' and input has ended" \
        "Nothing was written; ${TARGET_DISPLAY} is unchanged." \
        "Run scripts/setup-config.sh again, or use --non-interactive with --set ${path}=<value>."
    fi

    reply="$(trim "$reply")"
    if [[ -z "$reply" && "${has_default}" -eq 1 ]]; then
      reply="$default_value"
    fi

    if validate_value "$path" "$reply"; then
      wiz_set_value "$path" "$reply"
      return 0
    fi
    printf '      rejected: %s\n' "${WIZ_REJECTION}"
  done
}

# ─── The overwrite guard (R11.7) ─────────────────────────────────────────────

CONFIRM_WORD="overwrite"

guard_existing_file() {
  [[ "${TARGET_EXISTS}" -eq 1 ]] || return 0
  if [[ "${FORCE}" -eq 1 ]]; then
    printf 'Overwriting the existing %s (--force).\n' "${TARGET_DISPLAY}"
    return 0
  fi
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    die "${TARGET_DISPLAY} already exists and no confirmation is possible in --non-interactive mode" \
      "The file was NOT modified. Re-run with --force to overwrite it."
  fi

  local reply
  printf '%s already exists and holds your current configuration.\n' "${TARGET_DISPLAY}"
  printf 'Type %s to replace it, or anything else to abort: ' "${CONFIRM_WORD}"
  if ! IFS= read -r reply; then
    printf '\n'
    die "no confirmation was given; ${TARGET_DISPLAY} is unchanged"
  fi
  reply="$(printf '%s' "$(trim "$reply")" | tr 'A-Z' 'a-z')"
  if [[ "$reply" != "${CONFIRM_WORD}" ]]; then
    die "not confirmed; ${TARGET_DISPLAY} is unchanged" \
      "Re-run with --force to overwrite it without being asked."
  fi
  printf '\n'
  return 0
}

# ─── Collection ──────────────────────────────────────────────────────────────

count_prompts() {
  local path total=0
  for path in "${ORDERED_PATHS[@]}"; do
    if [[ "$(wiz_meta REQUIRED "$path")" == "true" || "${INCLUDE_OPTIONAL}" -eq 1 ]]; then
      total=$((total + 1))
    fi
  done
  printf '%s' "$total"
}

collect_interactive() {
  local path
  PROMPT_TOTAL="$(count_prompts)"
  for path in "${ORDERED_PATHS[@]}"; do
    if [[ "$(wiz_meta REQUIRED "$path")" == "true" || "${INCLUDE_OPTIONAL}" -eq 1 ]]; then
      prompt_field "$path"
    else
      # Optional and not asked about: keep what is there, else the template
      # default, so the written file still declares every field (R11.5, R11.6).
      local value=""
      value="$(current_default "$path")" || value=""
      wiz_set_value "$path" "$value"
    fi
  done
}

collect_non_interactive() {
  local path value missing=() invalid=()
  for path in "${ORDERED_PATHS[@]}"; do
    value=""
    if wiz_has_supplied "$path"; then
      value="$(wiz_supplied "$path")"
    elif value="$(env_value "$path")"; then
      :
    elif value="$(existing_value "$path")"; then
      :
    elif value="$(template_default "$path")"; then
      # A template default is trusted, exactly as the resolver trusts it.
      wiz_set_value "$path" "$value"
      continue
    else
      value=""
    fi

    if [[ -z "$value" ]]; then
      if [[ "$(wiz_meta REQUIRED "$path")" == "true" ]]; then
        missing+=("$path")
      fi
      continue
    fi

    if ! validate_value "$path" "$value"; then
      invalid+=("${path}: ${WIZ_REJECTION}")
      continue
    fi
    wiz_set_value "$path" "$value"
  done

  if [[ "${#invalid[@]}" -gt 0 ]]; then
    printf '\nsetup-config: %d supplied value(s) were rejected:\n' "${#invalid[@]}" >&2
    local entry
    for entry in "${invalid[@]}"; do
      printf '  - %s\n' "$entry" >&2
    done
    printf '  Nothing was written; %s is unchanged.\n' "${TARGET_DISPLAY}" >&2
    exit 1
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf '\nsetup-config: %d required input(s) have no value in --non-interactive mode:\n' \
      "${#missing[@]}" >&2
    local path_name
    for path_name in "${missing[@]}"; do
      printf '  - %s   (supply with --set %s=<value> or %s)\n' \
        "$path_name" "$path_name" "$(_config__env_name "$path_name")" >&2
    done
    printf '  Nothing was written; %s is unchanged.\n' "${TARGET_DISPLAY}" >&2
    exit 1
  fi
}

# ─── Region agreement (R11.11) ───────────────────────────────────────────────
#
# The account entries are discovered from the template: every field declared
# with format `accountId` names one, and its sibling `.region` is the region to
# compare. No role name is written down here, so a fourth account entry added to
# the template is checked without a change to this script.

ACCOUNT_PREFIXES=()
REGION_PATHS=()

# Discovered once, into arrays rather than a pipeline, because the consumers
# below prompt: a `while read … done < <(…)` loop would hand the generator's own
# output to the prompt's `read` as if the Replicator had typed it.
discover_account_entries() {
  local path prefix
  for path in "${ORDERED_PATHS[@]}"; do
    [[ "$(wiz_meta FORMAT "$path")" == "accountId" ]] || continue
    case "$path" in
      *.*) prefix="${path%.*}" ;;
      *) continue ;;
    esac
    ACCOUNT_PREFIXES+=("$prefix")
    if [[ "$(wiz_meta DECLARED "${prefix}.region")" == "1" ]]; then
      REGION_PATHS+=("${prefix}.region")
    fi
  done
}

discover_account_entries

enforce_region_agreement() {
  local attempt=0 path value distinct report seen
  [[ "${#REGION_PATHS[@]}" -gt 1 ]] || return 0

  while :; do
    distinct=0
    report=""
    seen=""
    for path in "${REGION_PATHS[@]}"; do
      value="$(wiz_value "$path")"
      report="${report}${report:+, }${path}=${value:-<unset>}"
      case "${seen}" in
        *"|${value}|"*) ;;
        *)
          seen="${seen}|${value}|"
          distinct=$((distinct + 1))
          ;;
      esac
    done

    [[ "${distinct}" -le 1 ]] && return 0

    printf '\nThe account entries are not in the same region: %s\n' "${report}" >&2
    printf 'The PoC has only been validated with one region for all accounts — cross-account\n' >&2
    printf 'SSM and PrivateLink wiring assume it.\n' >&2

    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      die "the account regions disagree and --non-interactive cannot ask again" \
        "Supply one region per account entry with --set, then re-run." \
        "Nothing was written; ${TARGET_DISPLAY} is unchanged."
    fi

    attempt=$((attempt + 1))
    if [[ "${attempt}" -gt 5 ]]; then
      die "the account regions still disagree after ${attempt} attempts" \
        "Nothing was written; ${TARGET_DISPLAY} is unchanged."
    fi

    printf 'Enter the region for each account again.\n' >&2
    PROMPT_TOTAL=0
    for path in "${REGION_PATHS[@]}"; do
      # The prompt's default is the value just rejected, so re-prompting is not
      # a demand to retype everything — only the odd one out needs changing.
      printf -v "WIZ_SET__$(wiz_key "$path")" '%s' "$(wiz_value "$path")"
      prompt_field "$path"
    done
  done
}

# ─── Writing (R11.5, R11.6, R11.21, 1.6) ─────────────────────────────────────
#
# The template is the base document, so key order, indentation and the _doc
# block all survive, every declared field is present, and the output is the same
# JSON shape a hand-edit would produce. The write is atomic: build in memory,
# land in one .tmp, then mv — an interrupted wizard must not leave a half-written
# file for the resolver to read as gospel.

write_config() {
  local doc path value format tmp
  doc="$(cat "${TPL}")" || die "could not read ${TPL_DISPLAY}"

  for path in "${ORDERED_PATHS[@]}"; do
    value="$(wiz_value "$path")"
    format="$(wiz_meta FORMAT "$path")"
    # An optional field the template declares with no default and nobody
    # supplied keeps whatever the template holds, rather than being blanked.
    [[ -n "$value" ]] || continue
    if [[ "$format" == "boolean" ]]; then
      doc="$(printf '%s' "$doc" | jq --arg p "$path" \
        --argjson v "$(printf '%s' "$value" | tr 'A-Z' 'a-z')" \
        'setpath($p | split("."); $v)')" || die "could not set '${path}' while building the file"
    else
      doc="$(printf '%s' "$doc" | jq --arg p "$path" --arg v "$value" \
        'setpath($p | split("."); $v)')" || die "could not set '${path}' while building the file"
    fi
  done

  tmp="${TARGET}.tmp"
  printf '%s\n' "$doc" > "${tmp}" || die "could not write ${TARGET_DISPLAY}.tmp"
  if ! mv "${tmp}" "${TARGET}"; then
    rm -f "${tmp}"
    die "could not move ${TARGET_DISPLAY}.tmp into place"
  fi
}

# ─── Account verification (R11.14-11.17) ─────────────────────────────────────
#
# Read-only, best effort, never fatal: a Replicator may be configuring an
# account whose credentials they do not have yet, and a wizard that refuses to
# finish over that is a wizard people stop using. get-caller-identity is the
# only AWS call this script makes.

verify_accounts() {
  local prefix id profile region out actual checked=0 warned=0

  printf '\nVerifying each account with aws sts get-caller-identity (read-only)…\n'
  if [[ "${#ACCOUNT_PREFIXES[@]}" -eq 0 ]]; then
    printf '  (no account entries to verify)\n'
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    printf '  ! the AWS CLI is not on PATH, so nothing was verified — not a failure\n'
    printf '    (pass --no-verify to skip this step deliberately)\n'
    return 0
  fi

  for prefix in "${ACCOUNT_PREFIXES[@]}"; do
    id="$(wiz_value "${prefix}.accountId")"
    profile="$(wiz_value "${prefix}.profile")"
    region="$(wiz_value "${prefix}.region")"
    [[ -n "$id" && -n "$profile" ]] || continue
    checked=$((checked + 1))

    # Through the memo, as a statement: if a prompt already read this profile's
    # identity for a session-name default, that one call is reused rather than
    # repeated.
    if ! sts_identity "${profile}" "${region}"; then
      warned=$((warned + 1))
      printf '  ! %s: could not call sts get-caller-identity with profile %s — %s\n' \
        "${prefix}" "${profile}" "$(sts_failure "${profile}")"
      printf '    Not a failure: refresh credentials before deploying (see the aws-deployment steering rules).\n'
      continue
    fi
    out="${STS_IDENTITY_JSON}"

    actual="$(printf '%s' "$out" | jq -r '.Account // empty' 2>/dev/null)"
    if [[ -z "$actual" ]]; then
      warned=$((warned + 1))
      printf '  ! %s: sts get-caller-identity returned no account identifier for profile %s\n' \
        "${prefix}" "${profile}"
      continue
    fi

    if [[ "$actual" != "$id" ]]; then
      warned=$((warned + 1))
      printf '  ! %s: profile %s authenticates as account %s, but you entered %s\n' \
        "${prefix}" "${profile}" "$(redact_id "$actual")" "$(redact_id "$id")"
      printf '    Not a failure — the configuration was written as entered. Check the profile if this is a surprise.\n'
    else
      printf '  ✓ %s: profile %s authenticates as the account you entered (%s)\n' \
        "${prefix}" "${profile}" "$(redact_id "$id")"
    fi
  done

  if [[ "${checked}" -eq 0 ]]; then
    printf '  (no account entry had both an identifier and a profile to check)\n'
  elif [[ "${warned}" -gt 0 ]]; then
    printf '  %d of %d account(s) could not be confirmed — warnings only, nothing failed.\n' \
      "${warned}" "${checked}"
  fi
}

# ─── Run ─────────────────────────────────────────────────────────────────────

printf 'setup-config — guided setup for %s\n' "${TARGET_DISPLAY}"
printf '  declarations: %s (%d field(s))\n' "${TPL_DISPLAY}" "${#ORDERED_PATHS[@]}"
if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
  printf '  mode:         --non-interactive (no prompts)\n'
else
  printf '  mode:         interactive'
  [[ "${INCLUDE_OPTIONAL}" -eq 1 ]] && printf ', including optional fields'
  printf '\n'
  printf '  Press Enter to accept the value in [brackets]. Resource names fixed by the\n'
  printf '  upstream sample are not asked for.\n'
fi
printf '\n'

guard_existing_file

if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
  collect_non_interactive
else
  collect_interactive
fi

enforce_region_agreement
write_config

printf '\nWrote %s — %d field(s), every one the template declares.\n' \
  "${TARGET_DISPLAY}" "${#ORDERED_PATHS[@]}"
printf 'That file is git-ignored and is the only place your account identifiers are stored.\n'

if [[ "${NO_VERIFY}" -eq 1 ]]; then
  printf '\nSkipped account verification (--no-verify): no AWS call was made.\n'
else
  verify_accounts
fi

# ─── Closing hand-off (R11.20) ───────────────────────────────────────────────
#
# The wizard does not re-decide whether the configuration is ready. preflight.sh
# owns that verdict and that table, so the two cannot disagree.

PREFLIGHT="${SCRIPT_DIR}/preflight.sh"
if [[ ! -f "${PREFLIGHT}" ]]; then
  printf '\nsetup-config: scripts/preflight.sh is not present, so the configuration was not verified.\n' >&2
  printf '  Restore it with: git checkout -- scripts/preflight.sh\n' >&2
  exit 0
fi

printf '\nHanding off to scripts/preflight.sh for the verdict…\n\n'
if [[ "${SHOW_IDS}" -eq 1 ]]; then
  exec bash "${PREFLIGHT}" --show-ids
fi
exec bash "${PREFLIGHT}"
