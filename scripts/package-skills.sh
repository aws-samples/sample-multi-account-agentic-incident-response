#!/usr/bin/env bash
# package-skills.sh — Package Agent Space skill zips, per Agent Space
#
# The two spaces do NOT get the same catalog. agents/skills/manifest.json
# declares which skills belong to which space, and this script emits one output
# directory per space:
#
#   dist/skills/app-team/   frontend-triage.zip, report-standards.zip, …
#   dist/skills/platform/   payments-failure-investigation.zip, …
#
# Each per-skill zip carries SKILL.md at its root (plus references/ when the
# skill has one). Each space also gets a combined <space>-skills.zip holding
# <skill-name>/SKILL.md entries, for the bulk-upload path.
#
# The manifest is the only place the split is written down. This script holds it
# to that in both directions:
#   • a skill named in the manifest with no agents/skills/<name>/SKILL.md is an
#     error,
#   • a skill folder no space claims is an error,
#   • a skill assigned to a space with no .skills[<name>].agentTypes entry is an
#     error — agent_types is a required, silently-gating upload field.
# Either way nothing is packaged silently, which is the failure mode this check
# exists for.
#
# Two documented service limits are enforced here rather than discovered at
# upload time:
#   • a skill bundle must contain no scripts/ directory — the DevOps Agent skill
#     format is non-executable files only, and the service rejects the upload,
#   • a per-skill zip must stay under 6 MB.
#
# Usage:
#   scripts/package-skills.sh [--clean]
#
# Flags:
#   --clean   Remove existing dist/skills/ before packaging
#
# Requirements: 4.3 (uploadable zips), 11.2 (catalog scoped per space)

set -euo pipefail

# ------------------------------------------------------------------
# Resolve project root (script lives in scripts/)
# ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKILLS_DIR="${PROJECT_ROOT}/agents/skills"
SKILLS_MANIFEST="${SKILLS_DIR}/manifest.json"
OUTPUT_DIR="${PROJECT_ROOT}/dist/skills"

# ------------------------------------------------------------------
# Parse flags
# ------------------------------------------------------------------
CLEAN=false
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=true ;;
    -h|--help)
      echo "Usage: scripts/package-skills.sh [--clean]"
      echo ""
      echo "Packages the skills under agents/skills/ into per-space zips, using"
      echo "agents/skills/manifest.json as the space -> skills mapping."
      echo ""
      echo "Flags:"
      echo "  --clean   Remove dist/skills/ before creating new zips"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' is required to read agents/skills/manifest.json." >&2
  echo "       Install jq (for example: brew install jq) and re-run." >&2
  exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
  echo "ERROR: 'zip' is required to build the skill bundles." >&2
  exit 1
fi

if [[ ! -f "$SKILLS_MANIFEST" ]]; then
  echo "ERROR: agents/skills/manifest.json is missing." >&2
  echo "       It declares which skills go to which Agent Space; without it the" >&2
  echo "       split cannot be derived. Restore it with:" >&2
  echo "         git checkout -- agents/skills/manifest.json" >&2
  exit 1
fi

if ! jq -e '.spaces | type == "object" and (length > 0)' "$SKILLS_MANIFEST" >/dev/null 2>&1; then
  echo "ERROR: agents/skills/manifest.json declares no spaces under .spaces" >&2
  exit 1
fi

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
manifest_spaces() {
  jq -r '.spaces | keys_unsorted[]' "$SKILLS_MANIFEST"
}

manifest_skills_for_space() {
  jq -r --arg space "$1" '.spaces[$space].skills[]?' "$SKILLS_MANIFEST"
}

manifest_all_skills() {
  jq -r '[.spaces[].skills[]?] | unique[]' "$SKILLS_MANIFEST"
}

manifest_agent_type_skills() {
  jq -r '(.skills // {}) | keys_unsorted[]' "$SKILLS_MANIFEST"
}

manifest_agent_types_for_skill() {
  jq -c --arg name "$1" '.skills[$name].agentTypes // empty' "$SKILLS_MANIFEST"
}

# The DevOps Agent skill format is non-executable files only (markdown, PDFs,
# images, data), and a bundle carrying a scripts/ directory is rejected at
# upload. Catching it here names the offending skill instead of surfacing as an
# opaque API validation error half a catalog later.
validate_no_scripts_dir() {
  local skill_dir="$1" skill_name="$2"
  if [[ -d "${skill_dir}/scripts" ]]; then
    echo "  ERROR: ${skill_name}/ contains a scripts/ directory" >&2
    echo "         The DevOps Agent skill format is non-executable files only" >&2
    echo "         (markdown, PDFs, images, data); the service rejects a bundle" >&2
    echo "         with scripts/. Move the logic into repo scripts/ and describe" >&2
    echo "         it in SKILL.md, or put the data under ${skill_name}/references/." >&2
    return 1
  fi
  return 0
}

# Documented hard limit: 6 MB per skill zip.
MAX_SKILL_ZIP_BYTES=$((6 * 1024 * 1024))

zip_size_bytes() {
  # BSD stat (macOS) and GNU stat (Linux) disagree on the flag.
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

validate_zip_size() {
  local zip_path="$1" skill_name="$2" space="$3" bytes
  bytes="$(zip_size_bytes "$zip_path")"
  if [[ "$bytes" -gt "$MAX_SKILL_ZIP_BYTES" ]]; then
    echo "  ERROR: dist/skills/${space}/${skill_name}.zip is ${bytes} bytes," >&2
    echo "         over the ${MAX_SKILL_ZIP_BYTES}-byte (6 MB) per-skill limit the" >&2
    echo "         service enforces. Trim agents/skills/${skill_name}/references/." >&2
    return 1
  fi
  return 0
}

validate_frontmatter() {
  local skill_file="$1"
  local skill_name="$2"

  # Check that the file starts with YAML frontmatter delimiters
  if ! head -n 1 "$skill_file" | grep -q '^---$'; then
    echo "  ERROR: ${skill_name}/SKILL.md missing YAML frontmatter (no opening ---)" >&2
    return 1
  fi

  # Extract frontmatter block (between first and second ---)
  local frontmatter
  frontmatter=$(sed -n '2,/^---$/p' "$skill_file" | sed '$d')

  # Validate 'name' field exists
  if ! echo "$frontmatter" | grep -q '^name:'; then
    echo "  ERROR: ${skill_name}/SKILL.md frontmatter missing 'name' field" >&2
    return 1
  fi

  # Validate 'description' field exists
  if ! echo "$frontmatter" | grep -q '^description:'; then
    echo "  ERROR: ${skill_name}/SKILL.md frontmatter missing 'description' field" >&2
    return 1
  fi

  return 0
}

# ------------------------------------------------------------------
# Reconcile the manifest against the folders on disk — both directions
# ------------------------------------------------------------------
echo "=== Packaging skills from ${SKILLS_DIR} ==="
echo "    Split declared by: agents/skills/manifest.json"
echo ""

on_disk=""
for skill_dir in "${SKILLS_DIR}"/*/; do
  [[ -d "$skill_dir" ]] || continue
  name="$(basename "$skill_dir")"
  if [[ ! -f "${skill_dir}SKILL.md" ]]; then
    echo "  SKIP: ${name}/ (no SKILL.md — not a skill folder)"
    continue
  fi
  on_disk="${on_disk}${name}
"
done

declared="$(manifest_all_skills)"

reconcile_errors=0

# A skill the manifest claims but no folder provides.
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if [[ ! -f "${SKILLS_DIR}/${name}/SKILL.md" ]]; then
    echo "  ERROR: manifest lists '${name}' but agents/skills/${name}/SKILL.md does not exist" >&2
    reconcile_errors=$((reconcile_errors + 1))
  fi
done <<< "$declared"

# A skill folder no space claims — the silently-unpackaged case.
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if ! printf '%s\n' "$declared" | grep -qx -- "$name"; then
    echo "  ERROR: agents/skills/${name}/ is not assigned to any space in agents/skills/manifest.json" >&2
    echo "         Add it to a space's \"skills\" list (or to both) — an unassigned skill reaches no space." >&2
    reconcile_errors=$((reconcile_errors + 1))
  fi
done <<< "$on_disk"

# Every assigned skill needs its own agent_types. The field is required by the
# upload API and it silently gates eligibility, so a missing entry is the same
# class of failure as an unassigned folder: the skill reaches the space and is
# never loaded.
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  types="$(manifest_agent_types_for_skill "$name")"
  if [[ -z "$types" ]]; then
    echo "  ERROR: agents/skills/manifest.json has no .skills[\"${name}\"].agentTypes" >&2
    echo "         agent_types is required by the upload API and gates which incident" >&2
    echo "         phase may load the skill. Declare it — see the manifest comment for" >&2
    echo "         the accepted values and why GENERIC is the floor." >&2
    reconcile_errors=$((reconcile_errors + 1))
  elif ! jq -e --arg n "$name" '.skills[$n].agentTypes | type == "array" and length > 0' \
      "$SKILLS_MANIFEST" >/dev/null 2>&1; then
    echo "  ERROR: .skills[\"${name}\"].agentTypes must be a non-empty array" >&2
    reconcile_errors=$((reconcile_errors + 1))
  fi
done <<< "$declared"

# An .skills entry for a skill no space claims is dead configuration.
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if ! printf '%s\n' "$declared" | grep -qx -- "$name"; then
    echo "  ERROR: .skills[\"${name}\"] declares agent types for a skill no space claims" >&2
    reconcile_errors=$((reconcile_errors + 1))
  fi
done <<< "$(manifest_agent_type_skills)"

if [[ "$reconcile_errors" -gt 0 ]]; then
  echo "" >&2
  echo "=== Packaging aborted: ${reconcile_errors} manifest/folder mismatch(es) ===" >&2
  exit 1
fi

# Frontmatter validation, once per skill rather than once per space.
validation_errors=0
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if ! validate_frontmatter "${SKILLS_DIR}/${name}/SKILL.md" "$name"; then
    validation_errors=$((validation_errors + 1))
  fi
  if ! validate_no_scripts_dir "${SKILLS_DIR}/${name}" "$name"; then
    validation_errors=$((validation_errors + 1))
  fi
done <<< "$declared"

if [[ "$validation_errors" -gt 0 ]]; then
  echo "" >&2
  echo "=== Packaging aborted: ${validation_errors} skill(s) failed content validation ===" >&2
  exit 1
fi

# ------------------------------------------------------------------
# Clean if requested
# ------------------------------------------------------------------
if [[ "$CLEAN" == "true" ]] && [[ -d "$OUTPUT_DIR" ]]; then
  echo "Cleaning ${OUTPUT_DIR}..."
  rm -rf "$OUTPUT_DIR"
  echo ""
fi

# ------------------------------------------------------------------
# Package per space
# ------------------------------------------------------------------
total_zips=0
summary=""

while IFS= read -r space; do
  [[ -n "$space" ]] || continue

  space_out="${OUTPUT_DIR}/${space}"
  mkdir -p "$space_out"

  # A stale zip from a previous split would look like a current instruction, so
  # the space's own directory is emptied of zips before it is refilled.
  find "$space_out" -maxdepth 1 -name '*.zip' -exec rm -f {} +

  echo "  ${space}:"

  space_count=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    skill_dir="${SKILLS_DIR}/${name}"
    zip_path="${space_out}/${name}.zip"

    # SKILL.md at the zip root; references/ carried along when the skill has one.
    if [[ -d "${skill_dir}/references" ]]; then
      (cd "$skill_dir" && zip -q -r "$zip_path" SKILL.md references)
    else
      (cd "$skill_dir" && zip -q -j "$zip_path" SKILL.md)
    fi

    if ! validate_zip_size "$zip_path" "$name" "$space"; then
      exit 1
    fi

    echo "    OK: ${name}.zip  (agent_types $(manifest_agent_types_for_skill "$name"))"
    space_count=$((space_count + 1))
    total_zips=$((total_zips + 1))
  done <<< "$(manifest_skills_for_space "$space")"

  if [[ "$space_count" -eq 0 ]]; then
    echo "    ERROR: space '${space}' claims no skills in the manifest" >&2
    exit 1
  fi

  # Combined bundle for this space only: <skill-name>/SKILL.md entries.
  combined="${space_out}/${space}-skills.zip"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    combined_entries=("${name}/SKILL.md")
    if [[ -d "${SKILLS_DIR}/${name}/references" ]]; then
      combined_entries+=("${name}/references")
    fi
    (cd "$SKILLS_DIR" && zip -q -r "$combined" "${combined_entries[@]}")
  done <<< "$(manifest_skills_for_space "$space")"
  echo "    Combined: ${space}-skills.zip (${space_count} skills)"

  summary="${summary}${space}"$'\t'"${space_count}
"
done <<< "$(manifest_spaces)"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "=== Packaging Summary ==="
echo "  Output directory: ${OUTPUT_DIR}"
echo "  Per-skill zips:   ${total_zips}"
echo ""
while IFS=$'\t' read -r space count; do
  [[ -n "$space" ]] || continue
  echo "  dist/skills/${space}/ — ${count} skill(s), upload to the ${space} space only:"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    echo "    - ${name}.zip  agent_types=$(manifest_agent_types_for_skill "$name")"
  done <<< "$(manifest_skills_for_space "$space")"
  echo "    - ${space}-skills.zip (combined)"
  echo ""
done <<< "$summary"
echo "  Next: scripts/upload-skills.sh --dry-run  (prints the per-space upload plan)"
echo ""
