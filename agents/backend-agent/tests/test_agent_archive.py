"""Tests for the devops agent's S3 report archival.

The archive was `try: archive_to_s3() / except Exception: pass`, which made a
real failure (a missing s3:PutObject grant, a bucket name resolved wrong)
indistinguishable from an agent that never attempted the archive. It is now
logged, so the two cases read differently in the runtime logs.

Importing src.agent pulls in the Strands SDK, which is not a test dependency,
so a lightweight fake `strands` module is installed first (the same pattern
the kb-agent suite uses).
"""

from __future__ import annotations

import asyncio
import logging
import sys
import types
from pathlib import Path

import pytest

_BACKEND_AGENT_DIR = Path(__file__).resolve().parent.parent
_REPO_ROOT = _BACKEND_AGENT_DIR.parent.parent
sys.path.insert(0, str(_BACKEND_AGENT_DIR))
sys.path.insert(0, str(_REPO_ROOT))


def _install_fake_strands() -> None:
    """Install a minimal fake strands module so src.agent imports."""
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

from src import agent as agent_module  # noqa: E402


class _StubAgent:
    """Callable stand-in for the Strands agent — returns a fixed answer."""

    def __call__(self, prompt: str) -> str:
        return (
            "Runbook: checkout-latency-investigation\n"
            "Root cause: checkout-degraded, high confidence\n"
        )


@pytest.fixture
def stub_agent(monkeypatch) -> None:
    monkeypatch.setattr(agent_module, "create_agent", _StubAgent)


class TestArchiveIsAttempted:
    def test_completed_report_is_archived(self, stub_agent, monkeypatch) -> None:
        calls: list[str] = []

        def fake_archive(self, bucket=None, s3_client=None) -> str:
            calls.append(self.report_id)
            return f"reports/2026-01-01/{self.report_id}.json"

        monkeypatch.setattr(
            agent_module.InvestigationReport, "archive_to_s3", fake_archive
        )

        report = asyncio.run(agent_module.run_investigation("Checkout latency p99"))

        assert calls == [report.report_id]


class TestArchiveFailureIsLoggedNotSwallowed:
    @pytest.fixture
    def failing_archive(self, monkeypatch) -> None:
        def boom(self, bucket=None, s3_client=None) -> str:
            raise RuntimeError("AccessDenied: s3:PutObject")

        monkeypatch.setattr(
            agent_module.InvestigationReport, "archive_to_s3", boom
        )

    def test_run_investigation_does_not_raise(
        self, stub_agent, failing_archive
    ) -> None:
        report = asyncio.run(agent_module.run_investigation("Checkout latency p99"))

        assert report.status == "completed"

    def test_failure_is_logged_with_the_cause(
        self, stub_agent, failing_archive, caplog
    ) -> None:
        with caplog.at_level(logging.ERROR, logger=agent_module.__name__):
            report = asyncio.run(
                agent_module.run_investigation("Checkout latency p99")
            )

        assert "AccessDenied: s3:PutObject" in caplog.text
        assert report.report_id in caplog.text
