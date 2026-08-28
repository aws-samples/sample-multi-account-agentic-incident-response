"""Health-check contract test for the AgentCore Runtime A2A contract.

The runtime probes GET /ping and expects a 200 response. /health remains as a
legacy alias.
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

# Add the kb-agent package to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from kb_agent.app import app


def _call_app(path: str, method: str = "GET") -> tuple[int, dict]:
    """Drive the ASGI app directly and capture status + JSON body."""
    scope = {"type": "http", "path": path, "method": method}
    sent: list[dict] = []

    async def receive() -> dict:
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message: dict) -> None:
        sent.append(message)

    asyncio.run(app(scope, receive, send))

    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    body_bytes = b"".join(
        m.get("body", b"") for m in sent if m["type"] == "http.response.body"
    )
    return status, json.loads(body_bytes)


class TestPingEndpoint:
    """GET /ping must return 200 per the AgentCore A2A protocol contract."""

    def test_ping_returns_200(self) -> None:
        status, body = _call_app("/ping")
        assert status == 200
        assert body["status"] == "healthy"

    def test_health_alias_still_returns_200(self) -> None:
        status, body = _call_app("/health")
        assert status == 200
        assert body["status"] == "healthy"

    def test_unknown_path_returns_404(self) -> None:
        status, _ = _call_app("/nope")
        assert status == 404
