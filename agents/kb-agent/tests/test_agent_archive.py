"""Tests for the KB agent's S3 report archival.

The KB agent used to return a report and write nothing, while the devops
agent both returned a report and archived it — so "did a fallback agent
produce a report?" answered differently depending on which of the two was
delegated to. `investigate()` now archives, and a failed archive is logged
rather than swallowed.

Importing kb_agent.agent pulls in the Strands SDK, which is not a test
dependency, so the same lightweight fake-strands install as
test_agent_escalation_prompt.py runs first.
"""

from __future__ import annotations

import logging
import sys
import types
from pathlib import Path

import pytest

# kb-agent package + repo root (for agents.shared imports) on the path
_KB_AGENT_DIR = Path(__file__).resolve().parent.parent
_REPO_ROOT = _KB_AGENT_DIR.parent.parent
sys.path.insert(0, str(_KB_AGENT_DIR))
sys.path.insert(0, str(_REPO_ROOT))


def _install_fake_strands() -> None:
    """Install minimal fake strands modules so kb_agent.agent imports."""
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


class _StubAgent:
    """Callable stand-in for the Strands agent — returns a fixed answer."""

    def __init__(self, answer: str = "Documented cause: checkout-degraded") -> None:
        self.answer = answer
        self.prompts: list[str] = []

    def __call__(self, prompt: str) -> str:
        self.prompts.append(prompt)
        return self.answer


@pytest.fixture
def stub_agent(monkeypatch) -> _StubAgent:
    """Replace create_agent so no Bedrock call is made."""
    stub = _StubAgent()
    monkeypatch.setattr(agent_module, "create_agent", lambda: stub)
    return stub


@pytest.fixture
def archive_calls(monkeypatch) -> list[dict]:
    """Record archive_to_s3 calls instead of writing to S3."""
    calls: list[dict] = []

    def fake_archive(self, bucket=None, s3_client=None) -> str:
        calls.append({"report_id": self.report_id, "status": self.status})
        return f"reports/2026-01-01/{self.report_id}.json"

    monkeypatch.setattr(
        agent_module.InvestigationReport, "archive_to_s3", fake_archive
    )
    return calls


class TestInvestigateArchivesTheReport:
    """The completed report must be archived, like the devops agent's."""

    def test_archive_is_called_once(self, stub_agent, archive_calls) -> None:
        agent_module.investigate("Adoption status updates lag by 15 minutes")

        assert len(archive_calls) == 1

    def test_archived_report_is_the_returned_report(
        self, stub_agent, archive_calls
    ) -> None:
        report = agent_module.investigate("Checkout latency p99 above 2s")

        assert archive_calls[0]["report_id"] == report.report_id

    def test_archive_happens_after_telemetry_is_recorded(
        self, stub_agent, archive_calls
    ) -> None:
        """A report archived before telemetry lands would store zeroed
        telemetry — the smoke test validates those fields."""
        report = agent_module.investigate("Search failures on petsearch")

        assert archive_calls[0]["status"] == "completed"
        assert report.telemetry.duration_seconds >= 0.0

    def test_report_is_still_returned(self, stub_agent, archive_calls) -> None:
        report = agent_module.investigate("Payments failing at checkout")

        assert report.status == "completed"
        assert report.skills_enabled is False


class TestArchiveFailureIsLoggedNotSwallowed:
    """A real permission failure must be visible in the runtime logs."""

    @pytest.fixture
    def failing_archive(self, monkeypatch) -> None:
        def boom(self, bucket=None, s3_client=None) -> str:
            raise RuntimeError("AccessDenied: s3:PutObject")

        monkeypatch.setattr(
            agent_module.InvestigationReport, "archive_to_s3", boom
        )

    def test_investigate_does_not_raise(self, stub_agent, failing_archive) -> None:
        report = agent_module.investigate("Checkout latency p99 above 2s")

        assert report.status == "completed"

    def test_failure_is_logged_with_the_cause(
        self, stub_agent, failing_archive, caplog
    ) -> None:
        with caplog.at_level(logging.ERROR, logger=agent_module.__name__):
            report = agent_module.investigate("Checkout latency p99 above 2s")

        assert "AccessDenied: s3:PutObject" in caplog.text
        assert report.report_id in caplog.text
