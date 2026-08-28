"""Unit tests for skill_loader module."""

import os
import tempfile
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from agents.shared.skill_loader import (
    _parse_frontmatter,
    is_skills_enabled,
    load_skills,
)


SAMPLE_SKILL = """---
name: checkout-latency-investigation
description: Investigation for slow checkout
---

# Checkout latency investigation

Step 1: Check metrics
"""

SAMPLE_SKILL_2 = """---
name: search-investigation
description: Investigation for search issues
---

# Search investigation

Step 1: Check search service
"""


@pytest.fixture
def skills_dir(tmp_path):
    """Create a temporary skills directory with sample skills."""
    skill1 = tmp_path / "checkout-latency-investigation"
    skill1.mkdir()
    (skill1 / "SKILL.md").write_text(SAMPLE_SKILL)

    skill2 = tmp_path / "search-investigation"
    skill2.mkdir()
    (skill2 / "SKILL.md").write_text(SAMPLE_SKILL_2)

    # A directory without SKILL.md should be ignored
    empty = tmp_path / "no-skill"
    empty.mkdir()

    return str(tmp_path)


class TestParseFrontmatter:
    def test_parses_name_and_description(self):
        result = _parse_frontmatter(SAMPLE_SKILL)
        assert result["name"] == "checkout-latency-investigation"
        assert "slow checkout" in result["description"]

    def test_returns_empty_for_no_frontmatter(self):
        result = _parse_frontmatter("# Just a heading\nSome text")
        assert result == {}

    def test_handles_multiline_description(self):
        content = """---
name: test-skill
description: This is a long
  description that spans multiple lines
---
"""
        result = _parse_frontmatter(content)
        assert result["name"] == "test-skill"
        assert "long" in result["description"]
        assert "multiple lines" in result["description"]


class TestIsSkillsEnabled:
    def test_default_is_true(self, monkeypatch):
        monkeypatch.delenv("SKILLS_ENABLED", raising=False)
        assert is_skills_enabled() is True

    def test_env_false(self, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "false")
        assert is_skills_enabled() is False

    def test_env_true(self, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "true")
        assert is_skills_enabled() is True

    def test_ssm_overrides_env(self, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "true")
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "false"}}

        result = is_skills_enabled(ssm_client=mock_ssm)
        assert result is False

    def test_ssm_error_falls_through_to_env(self, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "true")
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.side_effect = Exception("SSM unreachable")

        result = is_skills_enabled(ssm_client=mock_ssm)
        assert result is True


class TestLoadSkills:
    def test_loads_all_skills(self, skills_dir, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "true")
        monkeypatch.delenv("SKILLS_FILTER", raising=False)

        skills = load_skills(skills_dir=skills_dir)

        assert len(skills) == 2
        names = {s["name"] for s in skills}
        assert "checkout-latency-investigation" in names
        assert "search-investigation" in names

    def test_filter_restricts_skills(self, skills_dir, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "true")
        monkeypatch.setenv("SKILLS_FILTER", "search-investigation")

        skills = load_skills(skills_dir=skills_dir)

        assert len(skills) == 1
        assert skills[0]["name"] == "search-investigation"

    def test_disabled_returns_empty(self, skills_dir, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "false")

        skills = load_skills(skills_dir=skills_dir)
        assert skills == []

    def test_nonexistent_dir_returns_empty(self, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "true")
        monkeypatch.delenv("SKILLS_FILTER", raising=False)

        skills = load_skills(skills_dir="/nonexistent/path")
        assert skills == []

    def test_skill_has_content(self, skills_dir, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "true")
        monkeypatch.delenv("SKILLS_FILTER", raising=False)

        skills = load_skills(skills_dir=skills_dir)

        checkout = next(s for s in skills if s["name"] == "checkout-latency-investigation")
        assert "Step 1" in checkout["content"]
        assert checkout["path"].endswith("SKILL.md")

    def test_ssm_disabled_returns_empty(self, skills_dir, monkeypatch):
        monkeypatch.setenv("SKILLS_ENABLED", "true")
        monkeypatch.delenv("SKILLS_FILTER", raising=False)
        mock_ssm = MagicMock()
        mock_ssm.get_parameter.return_value = {"Parameter": {"Value": "false"}}

        skills = load_skills(skills_dir=skills_dir, ssm_client=mock_ssm)
        assert skills == []
