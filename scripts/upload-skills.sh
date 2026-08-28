#!/usr/bin/env bash
# upload-skills.sh — Per-space skill upload for the two DevOps Agent spaces
#
# The two Agent Spaces get DIFFERENT catalogs. agents/skills/manifest.json is
# the single place that split is declared; scripts/package-skills.sh turns it
# into dist/skills/<space>/, and this script:
#
#   (a) verifies the per-space zips that manifest asks for actually exist and
#       that no stale zip is sitting in a space directory,
#   (b) uploads each space's zips to that space through the DevOps Agent asset
#       API, and
#   (c) re-reads the space with ListAssets and prints the resulting inventory.
#
# ─── How the upload works ──────────────────────────────────────────────────
# Skills are "assets" of type `skill`. There is no CreateSkill operation, but
# the generic asset operations in the installed service model
# (~/.aws/models/devops-agent/<version>/service-2.json) do the job, and
# `aws devops-agent list-asset-types` confirms `skill` is a real type
# ("Reusable instructions that extend agent capabilities"). The CLI namespace
# for this model is `aws devops-agent` — with the hyphen.
#
#   create-asset --agent-space-id <id> --asset-type skill \
#                --metadata '{name,description,agent_types}' \
#                --content '{"zip":{"zipFile":"<base64 zip>"}}'
#
# Two things the model does not tell you, learned from the live service:
#   * metadata.agent_types is REQUIRED for skill assets ("agent_types is
#     required for Skill knowledge items") and it is a HARD GATE on which
#     incident phase may load the skill — a skill scoped to a phase the run
#     never enters is never eligible, silently. It is not declared in the model
#     because metadata is a free-form Document, but the service enumerates the
#     enum in the ValidationException for an unknown value:
#       GENERIC, CHAT, INCIDENT_TRIAGE, INCIDENT_RCA, INCIDENT_MITIGATION,
#       PREVENTION, CHANGE_REVIEW, CHANGE_RELEASE, QUALITY_ASSURANCE_TESTING,
#       RELEASE_SHEPHERD, RELEASE_READINESS_REVIEW, RELEASE_TESTING,
#       SYSTEM_LEARNING, INCIDENT_UI
#     GENERIC is the service default and applies to ALL agent types, and it is
#     EXCLUSIVE: ["INCIDENT_RCA","GENERIC"] is rejected with "GENERIC agent type
#     cannot be combined with other agent types". Per skill the choice is
#     therefore GENERIC alone or an explicit phase list without GENERIC.
#     INCIDENT_TRIAGE is the decide-whether-to-investigate phase, so it is the
#     wrong home for an investigation runbook — that mistake is what made the
#     first upload of this catalog invisible during root-cause analysis. Each
#     skill declares its own values in agents/skills/manifest.json under
#     .skills[<name>].agentTypes; this script does not default them.
#   * assetId is service-assigned (ki-<uuid>), so it cannot be used as the
#     idempotency key. metadata.name is what identifies a skill across runs.
#   * skill_type (USER for what we upload, LEARNED for what the space learns on
#     its own) and status (ACTIVE / INACTIVE — the before/after demo toggle) are
#     both set by the service and returned inside metadata.
#
# Idempotency: every run lists the space first and matches on metadata.name.
# A skill that is already there is updated in place with UpdateAsset (PATCH) —
# or left completely untouched with --skip-existing. Neither path can create a
# duplicate. clientToken includes a hash of the zip so an interrupted run can be
# retried safely; reusing a token with a different payload is rejected with
# ConflictException, which is why the hash is in there and not a fixed string.
#
# Note that UpdateAsset bumps the asset version on every call, even when the zip
# has not changed and even when the clientToken is one the service has already
# seen — the token is not deduplicating updates. So repeat runs of the default
# path leave one asset per skill but a climbing version number; use
# --skip-existing when only the missing skills should be filled in.
#
# ─── Manual fallback ───────────────────────────────────────────────────────
# If the asset API is unavailable (older service model, missing permissions),
# each space can still be loaded by hand — the catalogs differ, so upload only
# the zips this script lists under a space:
#   1. Open the space's Operator Web App
#      (/aiops-poc/agent-spaces/<space>/operator-app-url in SSM, or
#      https://connect.aidevops.<region>.api.aws/spaces/<space-id>/operator).
#   2. Knowledge → Skills → Add skill → zip upload.
#   3. Upload dist/skills/<space>/*.zip for that space only (or the single
#      <space>-skills.zip bundle).
#   4. Each skill lands Active; the Active/Inactive toggle is the before/after
#      skills demo, no redeploy needed.
#
# Usage:
#   scripts/upload-skills.sh [--profile PROFILE] [--region REGION]
#                            [--space NAME] [--skip-existing] [--dry-run]
#
# Defaults (resolved by scripts/lib/config.sh):
#   --profile  config/accounts.json → ops.profile  (OPS account)
#   --region   config/accounts.json → ops.region
#
# --dry-run makes no AWS calls at all: it verifies the zips and prints the plan,
# so the split can be reviewed without credentials.
#
# Requirements: 4.3 (skills reach their space), 11.2 (catalog scoped per space)

set -euo pipefail

# ─── Resolve paths ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The OPS profile and region come from the Config_Resolver rather than from
# literals in this file — one shared location, no restated account details
# (Requirements 2.2, 2.3, 2.6).
source "${PROJECT_ROOT}/scripts/lib/config.sh"
SKILLS_DIR="${PROJECT_ROOT}/dist/skills"
SKILLS_SRC_DIR="${PROJECT_ROOT}/agents/skills"
SKILLS_MANIFEST="${PROJECT_ROOT}/agents/skills/manifest.json"

ASSET_TYPE_SKILL="skill"

# ─── Defaults ──────────────────────────────────────────────────────────────
PROFILE_FLAG=""
REGION_FLAG=""
SPACE_FILTER=""
DRY_RUN=false
SKIP_EXISTING=false

# ─── Parse arguments ───────────────────────────────────────────────────────
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
    --space)
      SPACE_FILTER="$2"
      shift 2
      ;;
    --skip-existing)
      SKIP_EXISTING=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--profile PROFILE] [--region REGION] [--space NAME] [--skip-existing] [--dry-run]"
      echo ""
      echo "Uploads the per-space skill zips in dist/skills/<space>/ to their Agent"
      echo "Space as assets of type '${ASSET_TYPE_SKILL}', then verifies with ListAssets."
      echo "Re-running is safe: an existing skill is updated, never duplicated."
      echo ""
      echo "Options:"
      echo "  --profile        AWS CLI profile (default: config/accounts.json → ops.profile)"
      echo "  --region         AWS region (default: config/accounts.json → ops.region)"
      echo "  --space          Only process this space from the manifest"
      echo "  --skip-existing  Leave already-uploaded skills untouched instead of updating them"
      echo "  --dry-run        Verify zips and print the plan; makes no AWS calls"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ─── Resolve the OPS account inputs ────────────────────────────────────────
config::init
config::account ops --profile-flag "$PROFILE_FLAG" --region-flag "$REGION_FLAG"
PROFILE="$CONFIG_OPS_PROFILE"
REGION="$CONFIG_OPS_REGION"

# ─── Read the split from the manifest ──────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' is required to read agents/skills/manifest.json." >&2
  exit 1
fi

if [[ ! -f "$SKILLS_MANIFEST" ]]; then
  echo "ERROR: agents/skills/manifest.json is missing — it declares which skills" >&2
  echo "       belong to which Agent Space. Restore it with:" >&2
  echo "         git checkout -- agents/skills/manifest.json" >&2
  exit 1
fi

manifest_spaces() {
  jq -r '.spaces | keys_unsorted[]' "$SKILLS_MANIFEST"
}

manifest_skills_for_space() {
  jq -r --arg space "$1" '.spaces[$space].skills[]?' "$SKILLS_MANIFEST"
}

# The agent types one skill is offered to. Declared per skill, never defaulted:
# these genuinely differ per skill (a triage-and-delegate procedure is needed in
# every phase, a root-cause runbook only in RCA), and a wrong default is
# invisible at upload time and only shows up as a skill that never loads.
manifest_agent_types_for_skill() {
  jq -c --arg name "$1" '.skills[$name].agentTypes // empty' "$SKILLS_MANIFEST"
}

SPACES="$(manifest_spaces)"
if [[ -z "${SPACES//[[:space:]]/}" ]]; then
  echo "ERROR: agents/skills/manifest.json declares no spaces under .spaces" >&2
  exit 1
fi

if [[ -n "$SPACE_FILTER" ]]; then
  if ! printf '%s\n' "$SPACES" | grep -qx -- "$SPACE_FILTER"; then
    echo "ERROR: --space '${SPACE_FILTER}' is not declared in the manifest." >&2
    echo "       Declared spaces: $(printf '%s' "$SPACES" | tr '\n' ' ')" >&2
    exit 1
  fi
  SPACES="$SPACE_FILTER"
fi

# ─── (a) Verify the per-space zips exist ───────────────────────────────────
if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "ERROR: dist/skills/ not found. Run scripts/package-skills.sh first." >&2
  exit 1
fi

missing=0
total_zips=0
while IFS= read -r space; do
  [[ -n "$space" ]] || continue
  space_dir="${SKILLS_DIR}/${space}"
  if [[ ! -d "$space_dir" ]]; then
    echo "ERROR: dist/skills/${space}/ is missing — the manifest declares that space." >&2
    echo "       Re-run scripts/package-skills.sh." >&2
    missing=$((missing + 1))
    continue
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ ! -f "${space_dir}/${name}.zip" ]]; then
      echo "ERROR: dist/skills/${space}/${name}.zip is missing — the manifest assigns" >&2
      echo "       '${name}' to the ${space} space. Re-run scripts/package-skills.sh." >&2
      missing=$((missing + 1))
    else
      total_zips=$((total_zips + 1))
    fi
  done <<< "$(manifest_skills_for_space "$space")"
done <<< "$SPACES"

if [[ "$missing" -gt 0 ]]; then
  echo "" >&2
  echo "Aborting: ${missing} expected zip(s)/directory(ies) missing from dist/skills/." >&2
  exit 1
fi

# A zip in dist/skills/<space>/ that the manifest does not assign there is a
# leftover from an earlier split, and this script would upload it to the wrong
# space.
stale=0
while IFS= read -r space; do
  [[ -n "$space" ]] || continue
  assigned="$(manifest_skills_for_space "$space")"
  for zip_path in "${SKILLS_DIR}/${space}"/*.zip; do
    [[ -f "$zip_path" ]] || continue
    zip_name="$(basename "$zip_path" .zip)"
    [[ "$zip_name" == "${space}-skills" ]] && continue
    if ! printf '%s\n' "$assigned" | grep -qx -- "$zip_name"; then
      echo "ERROR: dist/skills/${space}/${zip_name}.zip is not assigned to the ${space}" >&2
      echo "       space by the manifest — stale output. Re-run scripts/package-skills.sh --clean." >&2
      stale=$((stale + 1))
    fi
  done
done <<< "$SPACES"

if [[ "$stale" -gt 0 ]]; then
  echo "" >&2
  echo "Aborting: ${stale} stale zip(s) in dist/skills/." >&2
  exit 1
fi

# Every skill about to be uploaded must declare its agent types. Checked for the
# whole plan up front, not per skill mid-upload, so a missing entry cannot leave
# half a catalog uploaded.
untyped=0
while IFS= read -r space; do
  [[ -n "$space" ]] || continue
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -z "$(manifest_agent_types_for_skill "$name")" ]]; then
      echo "ERROR: agents/skills/manifest.json has no .skills[\"${name}\"].agentTypes," >&2
      echo "       and the ${space} space is assigned that skill. agent_types is required" >&2
      echo "       by the asset API and gates which incident phase may load the skill;" >&2
      echo "       this script will not guess it." >&2
      untyped=$((untyped + 1))
    fi
  done <<< "$(manifest_skills_for_space "$space")"
done <<< "$SPACES"

if [[ "$untyped" -gt 0 ]]; then
  echo "" >&2
  echo "Aborting: ${untyped} skill(s) with no declared agent types." >&2
  exit 1
fi

echo "══════════════════════════════════════════════════════════════════════"
echo " DevOps Agent — per-space skill upload"
echo "══════════════════════════════════════════════════════════════════════"
echo "  Profile: ${PROFILE}"
echo "  Region:  ${REGION}"
echo "  Source:  dist/skills/<space>/ (${total_zips} per-skill zips verified)"
echo "  Split:   agents/skills/manifest.json"
echo "  Asset:   assetType=${ASSET_TYPE_SKILL} via aws devops-agent create-asset/update-asset"
if [[ "$SKIP_EXISTING" == "true" ]]; then
  echo "  Mode:    skip skills that already exist"
fi
if [[ "$DRY_RUN" == "true" ]]; then
  echo "  Mode:    DRY-RUN (no AWS calls)"
fi
echo "══════════════════════════════════════════════════════════════════════"
echo ""

# ─── Helpers ───────────────────────────────────────────────────────────────

# The space id is the last segment of the space ARN published by the
# agent-spaces stack. Neither the region nor the account appears as a literal.
resolve_space_id() {
  local space="$1" arn=""
  arn="$(aws ssm get-parameter \
    --name "/aiops-poc/agent-spaces/${space}/arn" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null)" || arn=""
  printf '%s' "${arn##*/}"
}

resolve_space_url() {
  local space="$1" url=""
  url="$(aws ssm get-parameter \
    --name "/aiops-poc/agent-spaces/${space}/operator-app-url" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null)" || url=""
  printf '%s' "$url"
}

# skill_frontmatter_field <SKILL.md> <field> — the value of one YAML frontmatter
# field, with wrapped continuation lines folded into one line. The skill's own
# name and description are what the space shows and what the agent matches on,
# so they are read from the skill rather than restated in the manifest.
skill_frontmatter_field() {
  awk -v field="$2" '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { exit }
    infm {
      if ($0 ~ "^" field ":[[:space:]]*") {
        sub("^" field ":[[:space:]]*", "")
        val = $0
        collecting = 1
        next
      }
      if (collecting) {
        if ($0 ~ /^[A-Za-z0-9_-]+:/) { collecting = 0 }
        else { line = $0; sub(/^[[:space:]]+/, "", line); val = val " " line; next }
      }
    }
    END { gsub(/[[:space:]]+$/, "", val); print val }
  ' "$1"
}

# List the skill assets already in a space as
# "assetId<TAB>name<TAB>skill_type<TAB>status<TAB>version<TAB>agent_types".
# agent_types is in the listing because it is the field that silently decides
# whether the skill is ever eligible, so it belongs in the verification output.
list_space_skills() {
  local space_id="$1"
  aws devops-agent list-assets \
    --agent-space-id "$space_id" \
    --asset-type "$ASSET_TYPE_SKILL" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --output json \
    | jq -r '.items[] | [
        .assetId,
        (.metadata.name // "-"),
        (.metadata.skill_type // "-"),
        (.metadata.status // "-"),
        (.version | tostring),
        ((.metadata.agent_types // []) | join(","))
      ] | @tsv'
}

# The assetId of the skill named $2 in the listing $1, or "" when absent.
# assetId is service-assigned, so metadata.name is the only stable key.
existing_asset_id() {
  local listing="$1" name="$2" line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local id rest row_name
    id="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    row_name="${rest%%$'\t'*}"
    if [[ "$row_name" == "$name" ]]; then
      printf '%s' "$id"
      return 0
    fi
  done <<< "$listing"
  printf '%s' ""
}

# A token that is stable for the same request and different for a changed one:
# a retry of an interrupted run is idempotent, while any change to what is being
# sent gets a fresh token instead of the ConflictException the service raises
# when a token is reused with a different payload.
#
# The digest covers the METADATA as well as the zip. Hashing the zip alone was a
# real trap: a rejected upload burns the token, and a fix that changes only
# agent_types or the description leaves the zip byte-identical, so every retry
# came back "A different request was already submitted with this clientToken"
# with no way forward short of touching the zip.
#
# The token is a hash rather than "space-name-digest" because the service caps
# clientToken at 64 characters — the model declares 1-128, but a 66-character
# token is rejected with a ValidationException naming 64 as the limit.
client_token_for() {
  local space="$1" name="$2" zip_path="$3" metadata="$4" digest
  digest="$(printf '%s/%s/%s/' "$space" "$name" "$metadata" | cat - "$zip_path" | shasum -a 256 | cut -c1-40)"
  printf 'skills-%s' "$digest"
}

# ─── (b) Upload each space's zips ──────────────────────────────────────────
created_rows=""
updated_rows=""
skipped_rows=""
failed_rows=""

upload_space() {
  local space="$1" space_id="$2"
  local listing name zip_path desc display_name asset_id token metadata content b64 out agent_types

  listing="$(list_space_skills "$space_id")" || {
    echo "ERROR: could not list assets in the ${space} space (${space_id})." >&2
    return 1
  }

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    zip_path="${SKILLS_DIR}/${space}/${name}.zip"
    display_name="$name"
    desc=""
    agent_types="$(manifest_agent_types_for_skill "$name")"
    if [[ -f "${SKILLS_SRC_DIR}/${name}/SKILL.md" ]]; then
      display_name="$(skill_frontmatter_field "${SKILLS_SRC_DIR}/${name}/SKILL.md" name)"
      desc="$(skill_frontmatter_field "${SKILLS_SRC_DIR}/${name}/SKILL.md" description)"
      [[ -n "$display_name" ]] || display_name="$name"
    fi

    asset_id="$(existing_asset_id "$listing" "$display_name")"

    if [[ -n "$asset_id" && "$SKIP_EXISTING" == "true" ]]; then
      echo "  = ${display_name} — already present (${asset_id}), skipped"
      skipped_rows="${skipped_rows}${space}"$'\t'"${display_name}"$'\t'"${asset_id}
"
      continue
    fi

    b64="$(base64 < "$zip_path" | tr -d '\n')"
    content="$(jq -n --arg z "$b64" '{zip:{zipFile:$z}}')"
    metadata="$(jq -n --arg n "$display_name" --arg d "$desc" --argjson t "$agent_types" \
      '{name:$n, agent_types:$t} + (if ($d | length) > 0 then {description:$d} else {} end)')"
    token="$(client_token_for "$space" "$display_name" "$zip_path" "$metadata")"

    if [[ -n "$asset_id" ]]; then
      # PATCH with a zip replaces all files in the asset and bumps its version.
      if out="$(aws devops-agent update-asset \
          --agent-space-id "$space_id" \
          --asset-id "$asset_id" \
          --metadata "$metadata" \
          --content "$content" \
          --client-token "$token" \
          --profile "$PROFILE" \
          --region "$REGION" \
          --output json 2>&1)"; then
        local version
        version="$(printf '%s' "$out" | jq -r '.asset.version')"
        echo "  ~ ${display_name} — updated (${asset_id}, version ${version}, agent_types ${agent_types})"
        updated_rows="${updated_rows}${space}"$'\t'"${display_name}"$'\t'"${asset_id}
"
      else
        echo "  ! ${display_name} — UpdateAsset failed: $(printf '%s' "$out" | tail -1)" >&2
        failed_rows="${failed_rows}${space}"$'\t'"${display_name}"$'\t'"update
"
      fi
      continue
    fi

    if out="$(aws devops-agent create-asset \
        --agent-space-id "$space_id" \
        --asset-type "$ASSET_TYPE_SKILL" \
        --metadata "$metadata" \
        --content "$content" \
        --client-token "$token" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --output json 2>&1)"; then
      local new_id new_status
      new_id="$(printf '%s' "$out" | jq -r '.asset.assetId')"
      new_status="$(printf '%s' "$out" | jq -r '.asset.metadata.status // "-"')"
      echo "  + ${display_name} — created (${new_id}, ${new_status}, agent_types ${agent_types})"
      created_rows="${created_rows}${space}"$'\t'"${display_name}"$'\t'"${new_id}
"
    else
      echo "  ! ${display_name} — CreateAsset failed: $(printf '%s' "$out" | tail -1)" >&2
      failed_rows="${failed_rows}${space}"$'\t'"${display_name}"$'\t'"create
"
    fi
  done <<< "$(manifest_skills_for_space "$space")"
}

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Planned uploads (no AWS calls made):"
  echo ""
  while IFS= read -r space; do
    [[ -n "$space" ]] || continue
    role="$(jq -r --arg s "$space" '.spaces[$s].role // ""' "$SKILLS_MANIFEST")"
    echo "──────────────────────────────────────────────────────────────────────"
    echo " ${space} space"
    [[ -n "$role" ]] && echo "   ${role}"
    echo "──────────────────────────────────────────────────────────────────────"
    echo "   space id: read from SSM /aiops-poc/agent-spaces/${space}/arn at run time"
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      echo "   + ${ASSET_TYPE_SKILL}: ${name}  agent_types=$(manifest_agent_types_for_skill "$name")"
      echo "       <- dist/skills/${space}/${name}.zip"
    done <<< "$(manifest_skills_for_space "$space")"
    echo ""
  done <<< "$SPACES"
  echo "══════════════════════════════════════════════════════════════════════"
  echo "DRY-RUN complete: zips verified against the manifest, no AWS calls made."
  echo "══════════════════════════════════════════════════════════════════════"
  exit 0
fi

upload_failures=0
while IFS= read -r space; do
  [[ -n "$space" ]] || continue
  role="$(jq -r --arg s "$space" '.spaces[$s].role // ""' "$SKILLS_MANIFEST")"
  space_id="$(resolve_space_id "$space")"

  echo "──────────────────────────────────────────────────────────────────────"
  echo " ${space} space"
  [[ -n "$role" ]] && echo "   ${role}"
  echo "──────────────────────────────────────────────────────────────────────"

  if [[ -z "$space_id" ]]; then
    echo "ERROR: could not read /aiops-poc/agent-spaces/${space}/arn from SSM." >&2
    echo "       Deploy the agent-spaces stack first, and check the credentials for" >&2
    echo "       profile '${PROFILE}' are current." >&2
    upload_failures=$((upload_failures + 1))
    echo ""
    continue
  fi
  echo "  space id: ${space_id}"

  if ! upload_space "$space" "$space_id"; then
    upload_failures=$((upload_failures + 1))
  fi
  echo ""
done <<< "$SPACES"

# ─── (c) Verify: re-read each space and print its inventory ────────────────
echo "══════════════════════════════════════════════════════════════════════"
echo " Per-space inventory (ListAssets, assetType=${ASSET_TYPE_SKILL})"
echo "══════════════════════════════════════════════════════════════════════"

verify_failures=0
while IFS= read -r space; do
  [[ -n "$space" ]] || continue
  space_id="$(resolve_space_id "$space")"
  [[ -n "$space_id" ]] || continue

  echo ""
  echo "── ${space} space (${space_id})"
  listing="$(list_space_skills "$space_id")" || {
    echo "ERROR: ListAssets failed for the ${space} space." >&2
    verify_failures=$((verify_failures + 1))
    continue
  }
  printf '   %-38s %-8s %-9s %-4s %s\n' "NAME" "TYPE" "STATUS" "VER" "AGENT_TYPES"
  while IFS=$'\t' read -r aid aname atype astatus aver atypes; do
    [[ -n "$aid" ]] || continue
    printf '   %-38s %-8s %-9s %-4s %s\n' "$aname" "$atype" "$astatus" "$aver" "$atypes"
  done <<< "$listing"

  # Every skill the manifest assigns here must now be present. A LEARNED skill
  # the space discovered on its own is expected and is not reported as extra.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    display_name="$name"
    if [[ -f "${SKILLS_SRC_DIR}/${name}/SKILL.md" ]]; then
      display_name="$(skill_frontmatter_field "${SKILLS_SRC_DIR}/${name}/SKILL.md" name)"
      [[ -n "$display_name" ]] || display_name="$name"
    fi
    if [[ -z "$(existing_asset_id "$listing" "$display_name")" ]]; then
      echo "   MISSING: the manifest assigns '${display_name}' to ${space} but it is not in the space." >&2
      verify_failures=$((verify_failures + 1))
      continue
    fi
    # The upload landing is not enough — a skill with the wrong agent_types is
    # present and unusable, which is exactly the failure that went unnoticed the
    # first time this catalog was uploaded.
    # Compared as a sorted set — the service is not documented to preserve the
    # order the values were sent in.
    want="$(manifest_agent_types_for_skill "$name" | jq -r 'sort | join(",")')"
    got="$(printf '%s\n' "$listing" \
      | awk -F'\t' -v n="$display_name" '$2 == n { print $6 }' \
      | tr ',' '\n' | sort | paste -sd, -)"
    if [[ "$want" != "$got" ]]; then
      echo "   AGENT_TYPES MISMATCH: '${display_name}' in ${space} is [${got}], manifest says [${want}]." >&2
      verify_failures=$((verify_failures + 1))
    fi
  done <<< "$(manifest_skills_for_space "$space")"
done <<< "$SPACES"

echo ""
echo "══════════════════════════════════════════════════════════════════════"
count_rows() { printf '%s' "$1" | grep -c . || true; }
echo "  created: $(count_rows "$created_rows")   updated: $(count_rows "$updated_rows")   skipped: $(count_rows "$skipped_rows")   failed: $(count_rows "$failed_rows")"
if [[ -n "${failed_rows//[[:space:]]/}" ]]; then
  echo ""
  echo "  Skills that did NOT land (space / skill / operation):" >&2
  printf '%s' "$failed_rows" | while IFS=$'\t' read -r s n op; do
    [[ -n "$s" ]] || continue
    echo "    ${s} / ${n} / ${op}" >&2
  done
fi
echo "  Skills land ACTIVE. metadata.status (ACTIVE / INACTIVE) is the"
echo "  before/after skills demo toggle and is visible through ListAssets."
echo "══════════════════════════════════════════════════════════════════════"

if [[ "$upload_failures" -gt 0 || "$verify_failures" -gt 0 || -n "${failed_rows//[[:space:]]/}" ]]; then
  exit 1
fi
