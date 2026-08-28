"""Tests for the escalation steering in the KB agent system prompt.

Importing kb_agent.agent pulls in the Strands SDK, which is not a test
dependency — so lightweight fake `strands` modules are installed in
sys.modules first (same spirit as the lazy-import pattern in mcp_server).
"""

from __future__ import annotations

import sys
import types
from pathlib import Path

# kb-agent package + repo root (for agents.shared imports) on the path
_KB_AGENT_DIR = Path(__file__).resolve().parent.parent
_REPO_ROOT = _KB_AGENT_DIR.parent.parent
sys.path.insert(0, str(_KB_AGENT_DIR))
sys.path.insert(0, str(_REPO_ROOT))


def _install_fake_strands() -> None:
    """Install minimal fake strands modules so kb_agent.agent imports."""
    if "strands" in sys.modules and not isinstance(
        getattr(sys.modules["strands"], "__fake__", None), bool
    ):
        # Real strands already importable — nothing to fake
        try:
            import strands  # noqa: F401
            return
        except ImportError:
            pass

    strands_mod = types.ModuleType("strands")
    strands_mod.__fake__ = True

    def tool(func=None, **_kwargs):
        if func is not None:
            return func
        return lambda f: f

    class Agent:
        def __init__(self, **kwargs) -> None:
            self.kwargs = kwargs

    strands_mod.tool = tool
    strands_mod.Agent = Agent

    models_mod = types.ModuleType("strands.models")
    bedrock_mod = types.ModuleType("strands.models.bedrock")

    class BedrockModel:
        def __init__(self, **kwargs) -> None:
            self.kwargs = kwargs

    bedrock_mod.BedrockModel = BedrockModel

    sys.modules["strands"] = strands_mod
    sys.modules["strands.models"] = models_mod
    sys.modules["strands.models.bedrock"] = bedrock_mod


_install_fake_strands()

from kb_agent import agent as agent_module  # noqa: E402


class TestSystemPromptEscalationAlways:
    """Default mode 'always' must make escalation mandatory."""

    def test_default_mode_is_always(self) -> None:
        # ESCALATION_MODE is unset in the test environment → default "always"
        assert agent_module._ESCALATION_MODE == "always"

    def test_prompt_contains_mandatory_escalation_rule(self) -> None:
        prompt = agent_module._build_system_prompt("always")
        assert "MUST call escalate_to_owner_team exactly once" in prompt
        assert "BEFORE producing the final report" in prompt
        assert "Never skip it" in prompt

    def test_prompt_lists_escalate_tool_in_available_tools(self) -> None:
        prompt = agent_module._build_system_prompt("always")
        assert "escalate_to_owner_team: Notify the service-owning team" in prompt

    def test_prompt_has_escalation_step_in_approach(self) -> None:
        prompt = agent_module._build_system_prompt("always")
        assert "5. Call escalate_to_owner_team exactly once" in prompt
        assert "6. Produce the final report" in prompt

    def test_report_format_includes_escalation_field(self) -> None:
        prompt = agent_module._build_system_prompt("always")
        assert "escalation: { sent: bool, message_id: str|null }" in prompt

    def test_module_level_prompt_uses_default_mode(self) -> None:
        assert "MUST call escalate_to_owner_team exactly once" in agent_module.SYSTEM_PROMPT


class TestSystemPromptEscalationAuto:
    """Mode 'auto' softens the rule — escalate on root cause / low confidence."""

    def test_auto_mode_has_softer_rule(self) -> None:
        prompt = agent_module._build_system_prompt("auto")
        assert "MUST call escalate_to_owner_team exactly once" not in prompt
        assert "probable root cause" in prompt
        assert "escalate_to_owner_team" in prompt


class TestKnowledgeOnlyRole:
    """The 2026-07 descope: KB-grounded documentation checker, no telemetry."""

    def test_prompt_states_no_live_aws_access(self) -> None:
        prompt = agent_module._build_system_prompt("always")
        assert "NO live AWS access" in prompt
        assert "documentation-grounded" in prompt

    def test_prompt_describes_documentation_checker_role(self) -> None:
        prompt = agent_module._build_system_prompt("always")
        assert "KB-grounded documentation checker" in prompt
        assert "checks the owning team should perform" in prompt

    def test_prompt_does_not_offer_telemetry_tools(self) -> None:
        prompt = agent_module._build_system_prompt("always")
        for removed in (
            "get_recent_alarms",
            "get_metric_stats",
            "get_service_health",
            "get_dynamodb_health",
            "get_queue_stats",
            "get_db_health",
            "get_lambda_stats",
            "get_canary_results",
        ):
            assert removed not in prompt

    def test_report_format_has_recommended_checks(self) -> None:
        prompt = agent_module._build_system_prompt("always")
        assert "recommended_checks" in prompt


class TestCreateAgentTools:
    """create_agent must register ONLY kb_retrieve + escalation (descope)."""

    def test_tools_include_escalate_to_owner_team(self) -> None:
        agent = agent_module.create_agent()
        tools = agent.kwargs["tools"]
        assert agent_module.tool_escalate_to_owner_team in tools

    def test_tools_are_exactly_kb_retrieve_and_escalate(self) -> None:
        agent = agent_module.create_agent()
        assert agent.kwargs["tools"] == [
            agent_module.tool_kb_retrieve,
            agent_module.tool_escalate_to_owner_team,
        ]

    def test_telemetry_wrappers_are_gone(self) -> None:
        for removed in (
            "tool_get_recent_alarms",
            "tool_get_metric_stats",
            "tool_get_service_health",
            "tool_get_dynamodb_health",
            "tool_get_queue_stats",
            "tool_get_db_health",
            "tool_get_lambda_stats",
            "tool_get_canary_results",
        ):
            assert not hasattr(agent_module, removed)

    def test_agent_gets_the_system_prompt(self) -> None:
        agent = agent_module.create_agent()
        assert agent.kwargs["system_prompt"] == agent_module.SYSTEM_PROMPT


class TestToolWrapper:
    """The Strands wrapper must delegate to escalation_tool with a nudging docstring."""

    def test_docstring_nudges_usage(self) -> None:
        doc = agent_module.tool_escalate_to_owner_team.__doc__
        assert "Notify the service-owning team" in doc
        assert "once per investigation after evidence gathering" in doc

    def test_wrapper_delegates(self, monkeypatch) -> None:
        captured: dict = {}

        def fake_escalate(summary, root_cause, evidence, kb_citations):
            captured["args"] = (summary, root_cause, evidence, kb_citations)
            return "Escalation sent (SNS MessageId: m-1)."

        monkeypatch.setattr(agent_module, "escalate_to_owner_team", fake_escalate)

        result = agent_module.tool_escalate_to_owner_team("s", "r", "e", "c")

        assert captured["args"] == ("s", "r", "e", "c")
        assert "m-1" in result
