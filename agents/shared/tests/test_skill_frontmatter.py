"""Frontmatter lint test — validates all SKILL.md files have required fields.

Every skill file in agents/skills/ must have valid YAML-like frontmatter with
at minimum: name and description.  This test discovers all SKILL.md files and
verifies compliance with the Agent Skills spec (agentskills.io).

Requirements: 11.1
"""

from __future__ import annotations

from pathlib import Path

import pytest

# Skills directory relative to this test file
_SKILLS_DIR = Path(__file__).resolve().parent.parent.parent / "skills"

REQUIRED_FRONTMATTER_FIELDS = ["name", "description"]


def _parse_frontmatter(content: str) -> dict[str, str]:
    """Parse YAML-style frontmatter delimited by --- lines."""
    lines = content.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}

    frontmatter: dict[str, str] = {}
    current_key = ""
    current_value = ""

    for line in lines[1:]:
        if line.strip() == "---":
            if current_key:
                frontmatter[current_key] = current_value.strip()
            break
        if ":" in line and not line.startswith(" "):
            if current_key:
                frontmatter[current_key] = current_value.strip()
            key, _, value = line.partition(":")
            current_key = key.strip()
            current_value = value.strip()
        else:
            # Continuation line (multi-line value)
            current_value += " " + line.strip()

    return frontmatter


def _discover_skill_files() -> list[Path]:
    """Find all SKILL.md files under agents/skills/."""
    if not _SKILLS_DIR.is_dir():
        return []
    return sorted(_SKILLS_DIR.glob("*/SKILL.md"))


def _skill_ids() -> list[str]:
    """Return skill directory names for parametrize ids."""
    return [p.parent.name for p in _discover_skill_files()]


@pytest.fixture(params=_discover_skill_files(), ids=_skill_ids())
def skill_file(request: pytest.FixtureRequest) -> Path:
    """Parametrized fixture yielding each SKILL.md path."""
    return request.param


class TestSkillFrontmatter:
    """Validate that all SKILL.md files have required frontmatter."""

    def test_skills_directory_exists(self):
        assert _SKILLS_DIR.is_dir(), f"Skills directory not found: {_SKILLS_DIR}"

    def test_at_least_one_skill_exists(self):
        skills = _discover_skill_files()
        assert len(skills) > 0, "No SKILL.md files found in agents/skills/"

    def test_frontmatter_has_opening_delimiter(self, skill_file: Path):
        content = skill_file.read_text(encoding="utf-8")
        assert content.startswith("---"), (
            f"{skill_file.parent.name}/SKILL.md must start with '---' frontmatter delimiter"
        )

    def test_frontmatter_has_closing_delimiter(self, skill_file: Path):
        content = skill_file.read_text(encoding="utf-8")
        lines = content.split("\n")
        # Find the closing --- (must be after line 0)
        closing_found = any(
            line.strip() == "---" for line in lines[1:]
        )
        assert closing_found, (
            f"{skill_file.parent.name}/SKILL.md must have a closing '---' frontmatter delimiter"
        )

    def test_frontmatter_has_name(self, skill_file: Path):
        content = skill_file.read_text(encoding="utf-8")
        meta = _parse_frontmatter(content)
        assert "name" in meta, (
            f"{skill_file.parent.name}/SKILL.md is missing required 'name' field"
        )
        assert meta["name"].strip(), (
            f"{skill_file.parent.name}/SKILL.md has empty 'name' field"
        )

    def test_frontmatter_has_description(self, skill_file: Path):
        content = skill_file.read_text(encoding="utf-8")
        meta = _parse_frontmatter(content)
        assert "description" in meta, (
            f"{skill_file.parent.name}/SKILL.md is missing required 'description' field"
        )
        assert meta["description"].strip(), (
            f"{skill_file.parent.name}/SKILL.md has empty 'description' field"
        )

    def test_name_matches_directory(self, skill_file: Path):
        """Skill name in frontmatter should match the directory name."""
        content = skill_file.read_text(encoding="utf-8")
        meta = _parse_frontmatter(content)
        dir_name = skill_file.parent.name
        skill_name = meta.get("name", "")
        assert skill_name == dir_name, (
            f"{dir_name}/SKILL.md: frontmatter name '{skill_name}' "
            f"does not match directory name '{dir_name}'"
        )

    def test_description_minimum_length(self, skill_file: Path):
        """Description should be meaningful (at least 20 characters)."""
        content = skill_file.read_text(encoding="utf-8")
        meta = _parse_frontmatter(content)
        desc = meta.get("description", "")
        assert len(desc) >= 20, (
            f"{skill_file.parent.name}/SKILL.md: description is too short "
            f"({len(desc)} chars, minimum 20)"
        )
