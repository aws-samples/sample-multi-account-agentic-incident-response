"""MCP serving mode tests for the backend-devops-agent.

Validates the AgentCore MCP contract settings, tool registration, and that
the `investigate` tool wraps run_investigation (mocked — never calls
Bedrock or the Strands SDK).
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

# Ensure src is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import mcp_server


class FakeReport:
    """Stand-in for InvestigationReport."""

    def __init__(self, status: str = "completed") -> None:
        self.status = status

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(
            {
                "status": self.status,
                "root_cause": {"fault_id": "db-overload", "confidence": "high"},
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
        assert "fallback" in mcp_server.mcp.instructions.lower()

    def test_instructions_state_knowledge_only_role(self) -> None:
        """Descope 2026-07: runbook consultation, no live telemetry."""
        instructions = mcp_server.mcp.instructions
        assert "runbook-consultation" in instructions
        assert "NO live telemetry" in instructions
        assert "documented" in instructions


class TestInvestigateTool:
    """The single `investigate` tool must exist and wrap run_investigation."""

    def test_investigate_tool_is_registered(self) -> None:
        tools = asyncio.run(mcp_server.mcp.list_tools())
        names = [t.name for t in tools]
        assert names == ["investigate"]

    def test_tool_docstring_covers_skills(self) -> None:
        tools = asyncio.run(mcp_server.mcp.list_tools())
        description = tools[0].description.lower()
        for topic in ("checkout latency", "search", "payments", "fulfillment"):
            assert topic in description

    def test_tool_docstring_states_knowledge_only_role(self) -> None:
        """Descope 2026-07: runbook consultation, no live telemetry."""
        tools = asyncio.run(mcp_server.mcp.list_tools())
        description = tools[0].description
        assert "NO live telemetry" in description
        assert "runbook" in description.lower()
        assert "owning team" in description

    def test_investigate_wraps_run_investigation(self, monkeypatch) -> None:
        captured: dict = {}

        async def fake_run(symptom: str) -> FakeReport:
            captured["symptom"] = symptom
            return FakeReport()

        monkeypatch.setattr(mcp_server, "_run_investigation", fake_run)

        result = asyncio.run(
            mcp_server.investigate("Checkout latency p99 above 2 seconds")
        )

        assert captured["symptom"] == "Checkout latency p99 above 2 seconds"
        assert result["status"] == "completed"
        assert result["report"]["root_cause"]["fault_id"] == "db-overload"

    def test_investigate_propagates_report_status(self, monkeypatch) -> None:
        async def fake_run(symptom: str) -> FakeReport:
            return FakeReport(status="timed_out")

        monkeypatch.setattr(mcp_server, "_run_investigation", fake_run)

        result = asyncio.run(mcp_server.investigate("Slow API"))
        assert result["status"] == "timed_out"

    def test_investigate_via_mcp_call_tool(self, monkeypatch) -> None:
        """End-to-end through the MCP tool manager (structured output)."""

        async def fake_run(symptom: str) -> FakeReport:
            return FakeReport()

        monkeypatch.setattr(mcp_server, "_run_investigation", fake_run)

        content = asyncio.run(
            mcp_server.mcp.call_tool("investigate", {"symptom": "DB errors"})
        )
        # call_tool returns a content-block sequence; the tool's dict result
        # is serialized as JSON text in the first block.
        payload = json.loads(content[0].text)
        assert payload["status"] == "completed"
