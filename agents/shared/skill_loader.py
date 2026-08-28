"""Skill loader — loads skills from agents/skills/ directory.

Honors:
- SKILLS_ENABLED env var (true/false) — primary gate
- SKILLS_FILTER env var (comma-separated skill names) — allowlist
- /aiops-poc/skills-enabled SSM parameter — managed flag override
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any


_SKILLS_DIR = os.environ.get(
    "SKILLS_DIR",
    str(Path(__file__).resolve().parent.parent / "skills"),
)
_SSM_SKILLS_PARAM = os.environ.get("SSM_SKILLS_PARAM", "/aiops-poc/skills-enabled")


def _parse_frontmatter(content: str) -> dict[str, str]:
    """Parse simple YAML-style frontmatter from a SKILL.md file."""
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
            # Continuation line
            current_value += " " + line.strip()

    return frontmatter


def _is_skills_enabled_env() -> bool:
    """Check SKILLS_ENABLED env var (defaults to True)."""
    return os.environ.get("SKILLS_ENABLED", "true").lower() in ("true", "1", "yes")


def _get_skills_filter() -> list[str] | None:
    """Return allowlist from SKILLS_FILTER or None if unset."""
    raw = os.environ.get("SKILLS_FILTER", "").strip()
    if not raw:
        return None
    return [s.strip() for s in raw.split(",") if s.strip()]


def is_skills_enabled(ssm_client: Any | None = None) -> bool:
    """Determine whether skills are enabled.

    Priority:
    1. SSM parameter /aiops-poc/skills-enabled (if reachable)
    2. SKILLS_ENABLED env var
    3. Default: True
    """
    # Try SSM first
    if ssm_client:
        try:
            response = ssm_client.get_parameter(Name=_SSM_SKILLS_PARAM)
            value = response["Parameter"]["Value"].lower()
            return value in ("true", "1", "yes")
        except Exception:
            pass  # Fall through to env var

    return _is_skills_enabled_env()


def load_skills(
    skills_dir: str | None = None,
    ssm_client: Any | None = None,
) -> list[dict[str, str]]:
    """Load all enabled skills.

    Returns a list of dicts with keys: name, description, content, path.
    Respects SKILLS_ENABLED, SKILLS_FILTER, and the SSM managed flag.
    """
    if not is_skills_enabled(ssm_client):
        return []

    directory = Path(skills_dir or _SKILLS_DIR)
    if not directory.is_dir():
        return []

    name_filter = _get_skills_filter()
    skills: list[dict[str, str]] = []

    for skill_dir in sorted(directory.iterdir()):
        if not skill_dir.is_dir():
            continue

        skill_file = skill_dir / "SKILL.md"
        if not skill_file.exists():
            continue

        content = skill_file.read_text(encoding="utf-8")
        meta = _parse_frontmatter(content)
        skill_name = meta.get("name", skill_dir.name)

        # Apply filter
        if name_filter and skill_name not in name_filter:
            continue

        skills.append(
            {
                "name": skill_name,
                "description": meta.get("description", ""),
                "content": content,
                "path": str(skill_file),
            }
        )

    return skills
