"""Contract test: agent card satisfies DevOps Agent remote-agent required fields.

Requirements 8.3: Agent card must have name, description, supportedInterfaces,
capabilities, skills.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Add the kb-agent package to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from kb_agent.agent_card import AGENT_CARD


class TestAgentCardContract:
    """Verify the agent card satisfies DevOps Agent remote-agent registration."""

    def test_has_name(self) -> None:
        """Agent card MUST have a name field."""
        assert "name" in AGENT_CARD
        assert isinstance(AGENT_CARD["name"], str)
        assert len(AGENT_CARD["name"]) > 0

    def test_has_description(self) -> None:
        """Agent card MUST have a description field."""
        assert "description" in AGENT_CARD
        assert isinstance(AGENT_CARD["description"], str)
        assert len(AGENT_CARD["description"]) > 0

    def test_has_supported_interfaces(self) -> None:
        """Agent card MUST declare supportedInterfaces."""
        assert "supportedInterfaces" in AGENT_CARD
        interfaces = AGENT_CARD["supportedInterfaces"]
        assert isinstance(interfaces, list)
        assert "a2a" in interfaces

    def test_has_capabilities(self) -> None:
        """Agent card MUST declare capabilities."""
        assert "capabilities" in AGENT_CARD
        caps = AGENT_CARD["capabilities"]
        assert isinstance(caps, dict)
        # Must declare investigation capability
        assert caps.get("investigation") is True
        # Must NOT declare remediation
        assert caps.get("remediation") is False

    def test_has_skills(self) -> None:
        """Agent card MUST list skills."""
        assert "skills" in AGENT_CARD
        skills = AGENT_CARD["skills"]
        assert isinstance(skills, list)
        assert len(skills) > 0
        # Each skill must have name and description
        for skill in skills:
            assert "name" in skill
            assert "description" in skill
            assert isinstance(skill["name"], str)
            assert isinstance(skill["description"], str)

    def test_kb_grounded_skill_present(self) -> None:
        """Agent card MUST include a KB-grounded investigation skill."""
        skill_names = [s["name"] for s in AGENT_CARD["skills"]]
        assert "kb-grounded-investigation" in skill_names

    def test_investigation_only_constraint(self) -> None:
        """Agent card MUST declare investigation-only constraint (Req 8.5)."""
        assert "constraints" in AGENT_CARD
        constraints = AGENT_CARD["constraints"]
        assert constraints.get("investigationOnly") is True
        assert constraints.get("readOnly") is True

    def test_knowledge_base_capability(self) -> None:
        """KB agent MUST declare knowledgeBase capability (Req 8.2)."""
        assert AGENT_CARD["capabilities"].get("knowledgeBase") is True

    def test_name_is_backend_kb_agent(self) -> None:
        """Agent name must match the expected identifier."""
        assert AGENT_CARD["name"] == "backend-kb-agent"

    def test_timeout_declared(self) -> None:
        """Agent card SHOULD declare the timeout constraint."""
        assert AGENT_CARD["constraints"]["timeoutSeconds"] == 600
