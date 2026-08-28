"""MCP serving mode tests for the backend-kb-agent.

Validates the AgentCore MCP contract settings, tool registration, and that
the `investigate` tool wraps kb_agent.agent.investigate (mocked — never
calls Bedrock or the Strands SDK).
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

# Add the kb-agent package to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from kb_agent import mcp_server


class FakeReport:
    """Stand-in for InvestigationReport."""

    def __init__(self, status: str = "completed") -> None:
        self.status = status

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(
            {
                "status": self.status,
                "kb_citations": ["petadoptions-architecture.md"],
            },
            indent=indent,
        )


class TestAgentCoreMcpContract:
    """The FastMCP instance must follow the AgentCore Runtime MCP contract."""

    def test_host_binds_all_interfaces(self) -> None:
        assert mcp_server.mcp.settings.host == "0.0.0.0"  # nosec B104  # asserts the container bind address AgentCore Runtime requires

    def test_port_is_8000(self) -> None:
        assert mcp_server.mcp.settings.port == 8000

    def test_streamable_http_path_is_mcp(self) -> None:
        assert mcp_server.mcp.settings.streamable_http_path == "/mcp"

    def test_stateless_http(self) -> None:
        assert mcp_server.mcp.settings.stateless_http is True

    def test_server_has_instructions(self) -> None:
        assert mcp_server.mcp.instructions
        assert "knowledge base" in mcp_server.mcp.instructions.lower()

    def test_instructions_state_knowledge_only_role(self) -> None:
        """Descope 2026-07: KB-grounded consultation, no live telemetry."""
        instructions = mcp_server.mcp.instructions
        assert "NO live telemetry" in instructions
        assert "escalates" in instructions
        assert "owning team" in instructions


class TestInvestigateTool:
    """The single `investigate` tool must exist and wrap agent.investigate."""

    def test_investigate_tool_is_registered(self) -> None:
        tools = asyncio.run(mcp_server.mcp.list_tools())
        names = [t.name for t in tools]
        assert names == ["investigate"]

    def test_tool_docstring_mentions_kb_grounding(self) -> None:
        tools = asyncio.run(mcp_server.mcp.list_tools())
        description = tools[0].description.lower()
        assert "knowledge base" in description
        for topic in ("checkout latency", "search", "payments", "status lag"):
            assert topic in description

    def test_tool_docstring_states_knowledge_only_role(self) -> None:
        """Descope 2026-07: documented checks + citations, no live telemetry."""
        tools = asyncio.run(mcp_server.mcp.list_tools())
        description = tools[0].description
        assert "NO live telemetry" in description
        assert "documented" in description
        assert "citations" in description
        assert "escalates" in description

    def test_investigate_wraps_agent_investigate(self, monkeypatch) -> None:
        captured: dict = {}

        def fake_investigate(question: str) -> FakeReport:
            captured["question"] = question
            return FakeReport()

        monkeypatch.setattr(mcp_server, "_investigate", fake_investigate)

        result = mcp_server.investigate("Adoption status updates lag")

        assert captured["question"] == "Adoption status updates lag"
        assert result["status"] == "completed"
        assert result["report"]["kb_citations"] == ["petadoptions-architecture.md"]

    def test_investigate_propagates_report_status(self, monkeypatch) -> None:
        monkeypatch.setattr(
            mcp_server, "_investigate", lambda question: FakeReport(status="error")
        )

        result = mcp_server.investigate("Slow API")
        assert result["status"] == "error"

    def test_investigate_via_mcp_call_tool(self, monkeypatch) -> None:
        """End-to-end through the MCP tool manager (structured output)."""
        monkeypatch.setattr(mcp_server, "_investigate", lambda question: FakeReport())

        content = asyncio.run(
            mcp_server.mcp.call_tool("investigate", {"question": "DB errors"})
        )
        # call_tool returns a content-block sequence; the tool's dict result
        # is serialized as JSON text in the first block.
        payload = json.loads(content[0].text)
        assert payload["status"] == "completed"
