"""Agent card contract test.

Validates the agent card JSON has all required fields for DevOps Agent
remote-agent registration:
- name: non-empty string
- description: string
- supportedInterfaces: array (non-empty)
- capabilities: object
- skills: array (non-empty)
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure src is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.agent_card import get_agent_card


class TestAgentCardContract:
    """Contract tests for DevOps Agent remote-agent registration requirements."""

    def setup_method(self) -> None:
        """Get the agent card for each test."""
        self.card = get_agent_card()

    def test_card_is_dict(self) -> None:
        """Agent card must be a JSON-serializable dict."""
        assert isinstance(self.card, dict)

    def test_name_is_non_empty_string(self) -> None:
        """Agent card must have a non-empty 'name' field."""
        assert "name" in self.card
        assert isinstance(self.card["name"], str)
        assert len(self.card["name"]) > 0

    def test_description_is_string(self) -> None:
        """Agent card must have a 'description' field that is a string."""
        assert "description" in self.card
        assert isinstance(self.card["description"], str)
        assert len(self.card["description"]) > 0

    def test_supported_interfaces_is_non_empty_array(self) -> None:
        """Agent card must have 'supportedInterfaces' as a non-empty array."""
        assert "supportedInterfaces" in self.card
        assert isinstance(self.card["supportedInterfaces"], list)
        assert len(self.card["supportedInterfaces"]) > 0

    def test_supported_interfaces_entries_have_type(self) -> None:
        """Each entry in supportedInterfaces must have a 'type' field."""
        for interface in self.card["supportedInterfaces"]:
            assert isinstance(interface, dict)
            assert "type" in interface
            assert isinstance(interface["type"], str)

    def test_capabilities_is_object(self) -> None:
        """Agent card must have 'capabilities' as an object (dict)."""
        assert "capabilities" in self.card
        assert isinstance(self.card["capabilities"], dict)

    def test_skills_is_non_empty_array(self) -> None:
        """Agent card must have 'skills' as a non-empty array."""
        assert "skills" in self.card
        assert isinstance(self.card["skills"], list)
        assert len(self.card["skills"]) > 0

    def test_skills_entries_have_required_fields(self) -> None:
        """Each skill entry must have id, name, and description."""
        for skill in self.card["skills"]:
            assert isinstance(skill, dict)
            assert "id" in skill
            assert "name" in skill
            assert "description" in skill
            assert isinstance(skill["id"], str)
            assert isinstance(skill["name"], str)
            assert isinstance(skill["description"], str)
            assert len(skill["id"]) > 0
            assert len(skill["name"]) > 0

    def test_capabilities_has_investigation(self) -> None:
        """Capabilities must declare investigation support."""
        assert self.card["capabilities"].get("investigation") is True

    def test_capabilities_no_remediation(self) -> None:
        """Capabilities must declare NO remediation (investigation-only)."""
        assert self.card["capabilities"].get("remediation") is False

    def test_card_has_version(self) -> None:
        """Agent card should have a version field."""
        assert "version" in self.card
        assert isinstance(self.card["version"], str)

    def test_description_reflects_knowledge_only_role(self) -> None:
        """Descope 2026-07: runbook consultation, no live telemetry."""
        description = self.card["description"]
        assert "Runbook-consultation" in description
        assert "No live telemetry" in description

    def test_skills_are_consultation_flavored(self) -> None:
        """Skill ids/descriptions must reflect consultation, not live checks."""
        for skill in self.card["skills"]:
            assert "consultation" in skill["id"]
            assert "ocumented" in skill["description"] or "runbook" in skill["description"].lower()
