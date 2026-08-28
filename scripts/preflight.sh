#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/preflight.sh — Preflight_Command
#
# The read-only gate a Replicator runs before bootstrap.sh / deploy-all.sh.
# It answers one question: "will the deploy scripts be able to resolve every
# input they need, and is the local state they read consistent?"
#
#   scripts/preflight.sh              # dump inputs, run every check
#   scripts/preflight.sh --show-ids   # print account identifiers in full
#   scripts/preflight.sh --strict     # repo-hygiene warnings become failures
#   scripts/preflight.sh --quiet      # verdict, failures and warnings only
#
# MAKES NO AWS CALLS AT ALL (Requirement 9.2). Everything it reports is derived
# from config/accounts.json, config/accounts.json.template, and files on disk.
# P6 does run the local `aws` binary, but only in `--generate-cli-skeleton`
# mode, which resolves the service model on disk and returns a request template
# without contacting AWS: no endpoint, no credentials, no region needed.
# Account credentials are therefore never needed to run it, and its output is
# safe to paste into a ticket: account identifiers print as their last four
# digits unless --show-ids is given.
#
# Checks, in order:
#
#   P1  Every declared input resolves to a real value — one row per input with
#       its JSON path, value and origin, and a listed failure for EVERY field
#       that is missing, still a placeholder, or malformed (R9.1, R9.3).
#   P2  backend.region == frontend.region == ops.region, printing all three
#       values when they disagree (R9.4).
#   P3  Every local cdk.context.json holds only the three configured account
#       identifiers; anything else is a stale cached lookup from a previous
#       Replicator's accounts, reported with the file that holds it (R7.4).
#   P4  scripts/check-parameters.sh — the parameter-surface completeness proof.
#   P5  scripts/scan-secrets.sh — the tracked-file live-identifier scan (account
#       identifiers and CloudFormation-generated resource names).
#   P6  the local aws CLI resolves the `devops-agent` namespace AND its asset
#       operations, which is what scripts/upload-skills.sh needs. Offline check.
#   P7  a Docker daemon is reachable, because deploy-all.sh steps 3 and 4 build
#       container images locally (petsite and the two agent runtimes). Local
#       check, no AWS calls.
#
# ─── Why P5, P6 and P7 warn, and P1-P4 block ─────────────────────────────────
#
# P1-P4 are all about THIS deploy: an unresolvable input, a region split, a
# stale context entry or an undeclared parameter each make the very next
# `cdk deploy` fail, deploy into the wrong place, or wire a resource to
# something that no longer exists. Blocking is the whole point.
#
# P5 is repository hygiene. It answers "would committing this tree leak an
# account identifier?", which is a question about the git history, not about
# whether the deploy works. That is why it warns by default instead of blocking:
# a P5 finding cannot make the next `cdk deploy` fail. And whenever the tree
# does carry findings — a wave of cleanup in progress, a newly tracked fixture —
# wiring a hard failure on P5 into bootstrap.sh and deploy-all.sh would make
# every deploy impossible until the cleanup lands. A gate that blocks the work
# it is meant to protect gets switched off, and then it protects nothing. The
# default mode therefore stays deployable while still reporting the finding in
# full.
#
# P6 warns for the same reason, from the other direction: it is about a local
# tool, not about this repository's inputs. Every CDK stack deploys with an aws
# CLI that has never heard of `devops-agent`; what needs the namespace is the
# post-deploy script layer, and what needs its asset operations is only
# scripts/upload-skills.sh — the skills before/after axis. Blocking the whole
# deploy on an optional axis would be the gate-that-gets-switched-off again. But
# finding out after standing up three accounts is exactly the surprise preflight
# exists to prevent, so the finding is reported in full, names the remedy, and
# --strict promotes it.
#
# So P5 and P6 follow the pending-vs-failure split check-parameters.sh already
# uses for exactly this situation: reported in full, never silently ignored, and
# promoted to a hard failure by --strict. --strict is also passed through to
# check-parameters.sh, so `scripts/preflight.sh --strict` is the single command
# that asserts the strongest form of the contract — every blocking check, plus
# the hygiene scan, plus the DevOps Agent CLI-model check, plus
# check-parameters.sh's own strict mode. It exits 0 on the tree as it stands, so
# it is the mode to use when you want that assertion, and the mode to wire into
# CI if this repo ever gets one — with the caveat that P6 asserts something
# about the machine rather than the tree, so a runner with an older aws CLI
# fails --strict for a reason no commit can fix.
#
# Requirements: 9.1, 9.2, 9.3, 9.4, 7.4
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

SHOW_IDS=0
STRICT=0
QUIET=0

usage() {
  cat <<'EOF'
Usage: scripts/preflight.sh [--show-ids] [--strict] [--quiet]

Read-only pre-deployment gate. Makes no AWS calls. Prints one row per declared
input (JSON path, value, origin) and checks that the local state the deploy
scripts read is consistent.

  --show-ids  Print account identifiers in full instead of their last 4 digits
  --strict    Promote the repository-hygiene scan (scan-secrets.sh) and the
              `aws devops-agent` CLI-model check from warnings to blocking
              failures, and run check-parameters.sh in --strict mode too. It
              passes on the tree as it stands, so this is the mode to use when
              you want the strongest assertion — and the one to wire into CI.
  --quiet     Print only the checks summary, warnings, failures and verdict
  -h, --help  Show this help

Exit status: 0 when every blocking check passes, 1 when any fails, 2 on a
usage or prerequisite error.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-ids) SHOW_IDS=1 ;;
    --strict) STRICT=1 ;;
    --quiet | -q) QUIET=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'preflight: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# ─── Reporting ───────────────────────────────────────────────────────────────
# Nothing stops at the first problem: R9.3 requires every offending field to be
# listed, so a Replicator fixes the config once instead of once per field.

FAILURES=()
WARNINGS=()
NOTES=()
RESULTS=()

fail() { FAILURES+=("$1"); }
warn() { WARNINGS+=("$1"); }
note() { NOTES+=("$1"); }

# A finding that blocks this deploy only in --strict mode. Named the same way
# check-parameters.sh names its equivalent, because it is the same decision.
# $2 names the kind of finding for the --strict annotation; it defaults to the
# repository-hygiene wording P5 has always used.
warn_or_fail() {
  local kind="${2:-repository-hygiene finding}"
  if [[ "${STRICT}" -eq 1 ]]; then
    fail "$1 [--strict: ${kind} treated as failure]"
  else
    warn "$1"
  fi
}

say() { [[ "${QUIET}" -eq 1 ]] || printf '%s\n' "$1"; }
record() { RESULTS+=("$1"); }

# ─── Prerequisites ───────────────────────────────────────────────────────────

CONFIG_LIB="${SCRIPT_DIR}/lib/config.sh"
if [[ ! -f "${CONFIG_LIB}" ]]; then
  printf 'preflight: the Config_Resolver is missing at scripts/lib/config.sh\n' >&2
  printf '  restore it with: git checkout -- scripts/lib/config.sh\n' >&2
  exit 2
fi

# config::init exits non-zero on its own, naming the missing prerequisite (jq)
# or the missing configuration file, with the remedy — so no message is
# duplicated here.
# shellcheck source=scripts/lib/config.sh
source "${CONFIG_LIB}"
config::init

say "preflight — read-only pre-deployment gate (no AWS calls)"
say "  root:   ${PROJECT_ROOT}"
say "  config: ${CONFIG_FILE_DISPLAY_PATH}"
[[ "${STRICT}" -eq 1 ]] && say "  mode:   --strict (repository-hygiene findings are failures)"
say ""

# ─── Redaction ───────────────────────────────────────────────────────────────

redact_id() {
  local value="$1"
  if [[ "${SHOW_IDS}" -eq 1 || ${#value} -ne 12 ]]; then
    printf '%s' "${value}"
  else
    printf '********%s' "${value: -4}"
  fi
}

# Resolve one path without dying when it cannot be resolved. The resolver's
# `config::get` exits non-zero from inside the command substitution's subshell,
# so the caller sees an empty value and preflight keeps going to collect the
# rest of the report. (The backtick above is load-bearing: check-parameters.sh
# check C2 extracts config paths from `config::get <path>` text, and a bare
# mention in prose would be read as a call site reading a path named "exits".)
soft_get() {
  local value=""
  value="$(config::get "$1" 2>/dev/null)" || value=""
  printf '%s' "${value}"
}

# ─── P1 — every declared input resolves ──────────────────────────────────────
#
# config::dump is the row-per-input table R9.1 asks for, and it already resolves
# in the soft mode that reports MISSING / PLACEHOLDER / INVALID per row instead
# of dying on the first one. Parsing its rows back out is what turns that table
# into the explicit per-field failure list R9.3 requires: the origin column of a
# failed row is exactly one of those tokens and nothing else, so the last field
# of the row identifies it and the first field is the JSON path.

check_p1() {
  local dump_out dump_status row status path declared=0 offenders=0

  if [[ "${SHOW_IDS}" -eq 1 ]]; then
    dump_out="$(config::dump)"
  else
    dump_out="$(config::dump --redact)"
  fi
  dump_status=$?

  say "Resolved inputs"
  say "${dump_out}"
  say ""

  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    status="$(printf '%s' "${row}" | awk '{print $NF}')"
    path="$(printf '%s' "${row}" | awk '{print $1}')"
    case "${status}" in
      MISSING | PLACEHOLDER | INVALID | UNDECLARED)
        offenders=$((offenders + 1))
        case "${status}" in
          MISSING)
            fail "${path}: required input is not set — set it in ${CONFIG_FILE_DISPLAY_PATH}, export $(printf 'AIOPS_%s' "$(printf '%s' "${path}" | tr 'a-z.' 'A-Z_')"), or run scripts/setup-config.sh"
            ;;
          PLACEHOLDER)
            fail "${path}: still holds a placeholder value — replace it in ${CONFIG_FILE_DISPLAY_PATH} with the value for your own account"
            ;;
          INVALID)
            fail "${path}: value does not match the format ${CONFIG_TEMPLATE_DISPLAY_PATH} declares for it"
            ;;
          UNDECLARED)
            fail "${path}: read but not declared in ${CONFIG_TEMPLATE_DISPLAY_PATH}"
            ;;
        esac
        ;;
      *)
        # Header and rule rows end in ORIGIN / ------ and are not inputs.
        case "${path}" in
          JSON | ---------) ;;
          *) declared=$((declared + 1)) ;;
        esac
        ;;
    esac
  done <<< "${dump_out}"

  if [[ "${offenders}" -eq 0 ]]; then
    record "P1 declared inputs resolve            PASS (${declared} input(s))"
    if [[ "${dump_status}" -ne 0 ]]; then
      # Defensive: dump disagreeing with its own rows would mean the parse above
      # missed a status token, which must not read as a pass.
      fail "P1: config::dump reported a failure that no row explains — re-run scripts/preflight.sh without --quiet and read the table"
    fi
  else
    record "P1 declared inputs resolve            FAIL (${offenders} of $((declared + offenders)) input(s) unusable)"
  fi
}

# ─── P2 — the three account regions agree ────────────────────────────────────
#
# The demo has never been validated split across regions, and a split shows up
# as a cross-account lookup silently resolving nothing rather than as an error.

check_p2() {
  local be fe ops
  be="$(soft_get backend.region)"
  fe="$(soft_get frontend.region)"
  ops="$(soft_get ops.region)"

  if [[ -z "${be}" || -z "${fe}" || -z "${ops}" ]]; then
    note "P2: region agreement could not be checked — at least one of backend.region / frontend.region / ops.region does not resolve (see P1)."
    record "P2 account regions agree              SKIP (a region does not resolve)"
    return
  fi

  if [[ "${be}" == "${fe}" && "${fe}" == "${ops}" ]]; then
    record "P2 account regions agree              PASS (${be})"
    return
  fi

  fail "the three accounts are configured in different regions: backend.region=${be}, frontend.region=${fe}, ops.region=${ops} — the PoC has only been validated with one region for all three (cross-account SSM and PrivateLink wiring assume it)"
  record "P2 account regions agree              FAIL (${be} / ${fe} / ${ops})"
}

# ─── P3 — no stale account identifier in a local cdk.context.json ────────────
#
# CDK caches every Vpc.fromLookup / valueFromLookup result in cdk.context.json.
# A cache written against another Replicator's accounts resolves to resources
# that do not exist in these ones, and CDK will reuse it without complaint —
# which is precisely the failure mode R7.4 names.

context_files() {
  find "${PROJECT_ROOT}" \
    -type d \( -name node_modules -o -name cdk.out -o -name .git -o -name dist \
    -o -name .venv -o -name venv -o -name __pycache__ \) -prune -o \
    -type f -name cdk.context.json -print 2>/dev/null | sort
}

check_p3() {
  local be fe ops file rel hit lineno value scanned=0 stale=0

  be="$(soft_get backend.accountId)"
  fe="$(soft_get frontend.accountId)"
  ops="$(soft_get ops.accountId)"

  if [[ -z "${be}" || -z "${fe}" || -z "${ops}" ]]; then
    note "P3: the cdk.context.json scan could not run — at least one configured account identifier does not resolve (see P1), so there is nothing to compare cached identifiers against."
    record "P3 no stale cdk.context.json entry    SKIP (an account ID does not resolve)"
    return
  fi

  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    scanned=$((scanned + 1))
    rel="${file#"${PROJECT_ROOT}"/}"
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] || continue
      lineno="${hit%%:*}"
      value="${hit##*:}"
      case "${value}" in
        "${be}" | "${fe}" | "${ops}") continue ;;
      esac
      stale=$((stale + 1))
      fail "${rel}:${lineno}: cached context holds account $(redact_id "${value}"), which is not one of the three configured accounts — it is a stale lookup from another deployment. Delete ${rel} (CDK rewrites it on the next synth) or remove the affected entries."
    done < <(grep -onE '[0-9]{12}' -- "${file}" 2>/dev/null || true)
  done < <(context_files)

  if [[ "${stale}" -eq 0 ]]; then
    record "P3 no stale cdk.context.json entry    PASS (${scanned} file(s) scanned)"
  else
    record "P3 no stale cdk.context.json entry    FAIL (${stale} stale entry/entries in ${scanned} file(s))"
  fi
}

# ─── P4 / P5 — delegation ────────────────────────────────────────────────────

# delegate <relative script path> <label> [args...]
# Prints the delegate's own output on failure; a delegate that is absent is a
# note, not a failure, so preflight still works in a partial checkout.
DELEGATE_OUTPUT=""
DELEGATE_STATUS=0
delegate() {
  local rel="$1"
  shift
  DELEGATE_OUTPUT=""
  DELEGATE_STATUS=0
  if [[ ! -f "${PROJECT_ROOT}/${rel}" ]]; then
    return 2
  fi
  DELEGATE_OUTPUT="$(bash "${PROJECT_ROOT}/${rel}" "$@" 2>&1)"
  DELEGATE_STATUS=$?
  return 0
}

check_p4() {
  # --strict is passed through: preflight --strict means "assert the whole
  # feature has landed", and check-parameters.sh owns its own pending list.
  local present=0
  if [[ "${STRICT}" -eq 1 ]]; then
    delegate "scripts/check-parameters.sh" --strict --quiet || present=$?
  else
    delegate "scripts/check-parameters.sh" --quiet || present=$?
  fi
  if [[ "${present}" -ne 0 ]]; then
    note "P4: scripts/check-parameters.sh is not present, so the parameter-surface completeness proof did not run."
    record "P4 parameter surface declared         SKIP (check-parameters.sh absent)"
    return
  fi

  if [[ "${DELEGATE_STATUS}" -eq 0 ]]; then
    record "P4 parameter surface declared         PASS (check-parameters.sh)"
    return
  fi

  fail "check-parameters.sh exited ${DELEGATE_STATUS} — an input a component reads is not declared in ${CONFIG_TEMPLATE_DISPLAY_PATH}. Run scripts/check-parameters.sh for the full report."
  record "P4 parameter surface declared         FAIL (check-parameters.sh exit ${DELEGATE_STATUS})"
  if [[ "${QUIET}" -ne 1 && -n "${DELEGATE_OUTPUT}" ]]; then
    printf '%s\n\n' "${DELEGATE_OUTPUT}"
  fi
}

check_p5() {
  local count=0
  local present=0

  delegate "scripts/scan-secrets.sh" || present=$?
  if [[ "${present}" -ne 0 ]]; then
    note "P5: scripts/scan-secrets.sh is not present, so the tracked-file account-identifier scan did not run."
    record "P5 no account ID in a tracked file    SKIP (scan-secrets.sh absent)"
    return
  fi

  if [[ "${DELEGATE_STATUS}" -eq 0 ]]; then
    record "P5 no account ID in a tracked file    PASS (scan-secrets.sh)"
    return
  fi

  # The finding line is file:line:value for both of the scan's match classes, so
  # the value field is matched as "not a colon" rather than as twelve digits — a
  # generated resource name is a finding too, and counting only account-shaped
  # values would report a real failure as "0 finding(s)".
  count="$(printf '%s\n' "${DELEGATE_OUTPUT}" | grep -cE '^[^:]+:[0-9]+:[^:]+$' || true)"
  warn_or_fail "scan-secrets.sh exited ${DELEGATE_STATUS} with ${count} finding(s): a tracked file holds a live identifier — an account ID that is not one of the canonical placeholders, or a resource name carrying a CloudFormation-generated suffix — that scripts/scan-secrets.baseline does not accept. This does not affect whether this deploy works — it affects what a commit would publish. Run scripts/scan-secrets.sh for the full file:line:value list."
  if [[ "${STRICT}" -eq 1 ]]; then
    record "P5 no account ID in a tracked file    FAIL (${count} finding(s), --strict)"
  else
    record "P5 no account ID in a tracked file    WARN (${count} finding(s), non-blocking without --strict)"
  fi

  # The findings carry the very identifiers preflight redacts everywhere else,
  # so the preview redacts them too: file:line is what a Replicator needs to act
  # on, and scan-secrets.sh prints the full value when asked directly.
  if [[ "${QUIET}" -ne 1 && -n "${DELEGATE_OUTPUT}" ]]; then
    printf 'P5 — scan-secrets findings (file:line:value, first 10 of %d):\n' "${count}"
    local finding rel_line id
    while IFS= read -r finding; do
      [[ -n "${finding}" ]] || continue
      rel_line="${finding%:*}"
      id="${finding##*:}"
      printf '    %s:%s\n' "${rel_line}" "$(redact_id "${id}")"
    done < <(printf '%s\n' "${DELEGATE_OUTPUT}" | grep -E '^[^:]+:[0-9]+:[^:]+$' | head -n 10)
    if [[ "${count}" -gt 10 ]]; then
      printf '    … %d more\n' "$((count - 10))"
    fi
    printf '\n'
  fi
}

# ─── P6 — the local aws CLI resolves `devops-agent` and its asset operations ──
#
# upload-skills.sh, the four registration scripts and smoke-test.sh all shell
# out to `aws devops-agent …` (one word, with the hyphen). That namespace is not
# something this repository can provide: it comes either from a recent enough
# AWS CLI v2 — the service shipped in 2.34.20, and its asset operations, which
# are how a skill is created, only in 2.34.64 — or from a service model
# installed under ~/.aws/models by `aws configure add-model`. On a machine with
# neither, those scripts die with "Found invalid choice" (exit 252) after the
# three accounts are already deployed, which is exactly the surprise preflight
# exists to prevent.
#
# The probe is `--generate-cli-skeleton`: it resolves the service model and
# prints a request template WITHOUT calling AWS — no endpoint, no credentials,
# no region, no config file needed. That keeps this inside preflight's
# no-AWS-calls contract (R9.2). Two probes, because the two failure modes have
# different consequences: `list-agent-spaces` is the namespace itself, and
# `create-asset` is the asset surface only the skills axis needs.
#
# `aws devops-agent help` is NOT a usable probe: it exits 255 with "list index
# out of range" even when the model is installed and working.

DEVOPS_AGENT_DOC="docs/deployment.md#the-aws-devops-agent-cli-namespace"
DEVOPS_AGENT_ADD_MODEL="aws configure add-model --service-model file:///path/to/service-2.json --service-name devops-agent"

check_p6() {
  local ns_status=0 asset_status=0 cli_label=""

  if ! command -v aws > /dev/null 2>&1; then
    warn_or_fail "the aws CLI is not on PATH, so the 'devops-agent' namespace every post-deploy script step needs cannot be checked — and no deploy step can run either. Install AWS CLI v2, then re-run this gate. See ${DEVOPS_AGENT_DOC}." \
      "local-tooling finding"
    if [[ "${STRICT}" -eq 1 ]]; then
      record "P6 devops-agent CLI model resolves    FAIL (aws not on PATH, --strict)"
    else
      record "P6 devops-agent CLI model resolves    WARN (aws not on PATH, non-blocking without --strict)"
    fi
    return
  fi

  cli_label="$(aws --version 2>&1 | awk '{print $1}')"
  [[ -n "${cli_label}" ]] || cli_label="aws CLI version unknown"

  aws devops-agent list-agent-spaces --generate-cli-skeleton > /dev/null 2>&1
  ns_status=$?
  aws devops-agent create-asset --generate-cli-skeleton > /dev/null 2>&1
  asset_status=$?

  if [[ "${ns_status}" -ne 0 ]]; then
    warn_or_fail "the local aws CLI does not resolve the 'devops-agent' namespace (${cli_label}; 'aws devops-agent list-agent-spaces --generate-cli-skeleton' exited ${ns_status}). Every post-deploy script step fails without it — register-webhook.sh, register-platform-space-mcp.sh, register-fallback-agents-mcp.sh, register-diagnostics-mcp.sh, upload-skills.sh, and smoke-test.sh's investigation poll — so no alarm can reach an agent. The CDK stacks themselves deploy fine. Fix: upgrade AWS CLI v2 (the service shipped in 2.34.20, its asset/skill operations in 2.34.64), or install a service model with '${DEVOPS_AGENT_ADD_MODEL}'. See ${DEVOPS_AGENT_DOC}." \
      "DevOps Agent CLI-model finding"
    if [[ "${STRICT}" -eq 1 ]]; then
      record "P6 devops-agent CLI model resolves    FAIL (namespace unresolved, --strict)"
    else
      record "P6 devops-agent CLI model resolves    WARN (namespace unresolved, non-blocking without --strict)"
    fi
    return
  fi

  if [[ "${asset_status}" -ne 0 ]]; then
    warn_or_fail "the local aws CLI resolves 'devops-agent' but not its asset operations (${cli_label}; 'aws devops-agent create-asset --generate-cli-skeleton' exited ${asset_status}), so scripts/upload-skills.sh cannot create or update a skill and the skills before/after axis cannot run. Webhooks, MCP capability providers and the smoke test are unaffected. Fix: upgrade AWS CLI v2 to 2.34.64 or later (the release that added the Asset APIs), or install a service model that has them with '${DEVOPS_AGENT_ADD_MODEL}'. See ${DEVOPS_AGENT_DOC}." \
      "DevOps Agent CLI-model finding"
    if [[ "${STRICT}" -eq 1 ]]; then
      record "P6 devops-agent CLI model resolves    FAIL (asset/skill operations absent, --strict)"
    else
      record "P6 devops-agent CLI model resolves    WARN (asset/skill operations absent, non-blocking without --strict)"
    fi
    return
  fi

  record "P6 devops-agent CLI model resolves    PASS (${cli_label}, asset/skill operations present)"
}

# ─── P7 — a Docker daemon is running ─────────────────────────────────────────
#
# deploy-all.sh step 3 (FrontendStack) builds petsite from upstream source and
# step 4 (AgentsInfraStack) builds the two agent runtime images, both with a
# local `docker build`. Docker is listed under local tooling in
# docs/deployment.md, but "installed" and "running" are different things, and
# nothing checked the daemon: a stopped Docker Desktop / colima let bootstrap
# and step 1 pass, then killed step 3 with "failed to connect to the docker API
# … is the daemon running?" — AFTER the 45-90 minute upstream deploy. That is
# an hour of wall-clock spent to learn something knowable in a second, which is
# precisely what this gate is for.
#
# `docker info` is the probe rather than `docker version` or `command -v`: the
# client binary answers `version` with no daemon behind it, and `info` is the
# cheapest call that proves the socket actually answers. It talks only to the
# local daemon, so preflight's no-AWS-calls contract (R9.2) holds.
#
# It warns rather than fails, like P5 and P6: a machine with no Docker can
# still legitimately run the read-only gate, check-parameters, the unit tests
# and any `--skip-upstream` planning. --strict promotes it.

check_p7() {
  if ! command -v docker > /dev/null 2>&1; then
    warn_or_fail "docker is not on PATH, so deploy-all.sh step 3 (petsite image) and step 4 (the two agent runtime images) cannot build. Install Docker Desktop or colima and start it before deploying. See docs/deployment.md#accounts-and-prerequisites." \
      "local-tooling finding"
    if [[ "${STRICT}" -eq 1 ]]; then
      record "P7 docker daemon reachable            FAIL (docker not on PATH, --strict)"
    else
      record "P7 docker daemon reachable            WARN (docker not on PATH, non-blocking without --strict)"
    fi
    return
  fi

  if ! docker info > /dev/null 2>&1; then
    warn_or_fail "docker is installed but its daemon is not reachable, so deploy-all.sh step 3 (petsite image) and step 4 (the two agent runtime images) fail at 'docker build' — and they fail AFTER step 1's 45-90 minute upstream deploy. Start it (Docker Desktop, or 'colima start') and re-run this gate. See docs/deployment.md#accounts-and-prerequisites." \
      "local-tooling finding"
    if [[ "${STRICT}" -eq 1 ]]; then
      record "P7 docker daemon reachable            FAIL (daemon unreachable, --strict)"
    else
      record "P7 docker daemon reachable            WARN (daemon unreachable, non-blocking without --strict)"
    fi
    return
  fi

  local server
  server="$(docker info --format '{{.ServerVersion}}' 2>/dev/null)"
  [[ -n "${server}" ]] || server="version unknown"
  record "P7 docker daemon reachable            PASS (server ${server})"
}

# ─── Run ─────────────────────────────────────────────────────────────────────

check_p1
check_p2
check_p3
check_p4
check_p5
check_p6
check_p7

if [[ "${QUIET}" -ne 1 ]]; then
  printf 'Checks\n'
fi
for line in "${RESULTS[@]}"; do
  printf '  %s\n' "${line}"
done
printf '\n'

if [[ ${#NOTES[@]} -gt 0 ]]; then
  printf 'Notes:\n'
  for line in "${NOTES[@]}"; do
    printf '  - %s\n' "${line}"
  done
  printf '\n'
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  printf 'Warnings (%d) — reported, not blocking; --strict makes them failures:\n' "${#WARNINGS[@]}"
  for line in "${WARNINGS[@]}"; do
    printf '  - %s\n' "${line}"
  done
  printf '\n'
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  printf 'FAILURES (%d):\n' "${#FAILURES[@]}"
  for line in "${FAILURES[@]}"; do
    printf '  - %s\n' "${line}"
  done
  printf '\n'
  printf 'preflight: FAIL — %d blocking problem(s). Fix them before bootstrap.sh / deploy-all.sh; nothing above required AWS credentials.\n' \
    "${#FAILURES[@]}" >&2
  exit 1
fi

printf 'preflight: PASS — every input resolves, the three accounts share one region, no stale cached context.\n'
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  printf '  %d warning(s) reported above — repository hygiene or local tooling, not this deploy. Re-run with --strict to treat them as blocking.\n' \
    "${#WARNINGS[@]}"
fi
exit 0
