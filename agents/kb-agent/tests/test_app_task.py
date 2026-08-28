"""Tests for the A2A task endpoint (POST /).

The investigation function is mocked — these tests never call Bedrock.
"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

# Add the kb-agent package to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import kb_agent.app as app_module
from kb_agent.app import app


class FakeReport:
    """Stand-in for InvestigationReport."""

    def __init__(self, status: str = "completed") -> None:
        self.status = status
        self.kb_citations = ["petadoptions-architecture.md"]

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(
            {
                "status": self.status,
                "kb_citations": self.kb_citations,
            },
            indent=indent,
        )


def _post(path: str, body: bytes) -> tuple[int, dict]:
    """Drive the ASGI app directly with a POST request."""
    scope = {"type": "http", "path": path, "method": "POST"}
    sent: list[dict] = []

    async def receive() -> dict:
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message: dict) -> None:
        sent.append(message)

    asyncio.run(app(scope, receive, send))

    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    body_bytes = b"".join(
        m.get("body", b"") for m in sent if m["type"] == "http.response.body"
    )
    return status, json.loads(body_bytes)


class TestTaskEndpoint:
    """POST / must accept A2A task requests and return the task-result shape."""

    def test_a2a_message_returns_task_result(self, monkeypatch) -> None:
        captured: dict = {}

        def fake_investigate(symptom: str) -> FakeReport:
            captured["symptom"] = symptom
            return FakeReport()

        monkeypatch.setattr(app_module, "_run_investigation", fake_investigate)

        request = {
            "id": "task-123",
            "message": {
                "parts": [
                    {"type": "text", "text": "Checkout latency p99 above 2 seconds"}
                ]
            },
        }
        status, body = _post("/", json.dumps(request).encode())

        assert status == 200
        assert captured["symptom"] == "Checkout latency p99 above 2 seconds"
        assert body["id"] == "task-123"
        assert body["status"]["state"] == "completed"
        assert body["status"]["message"] == "completed"
        artifact = body["artifacts"][0]
        assert artifact["name"] == "investigation-report"
        report = json.loads(artifact["parts"][0]["text"])
        assert report["kb_citations"] == ["petadoptions-architecture.md"]

    def test_generates_task_id_when_missing(self, monkeypatch) -> None:
        monkeypatch.setattr(
            app_module, "_run_investigation", lambda symptom: FakeReport()
        )

        request = {"message": {"parts": [{"type": "text", "text": "DB errors"}]}}
        status, body = _post("/", json.dumps(request).encode())

        assert status == 200
        assert body["id"]  # generated UUID

    def test_symptom_fallback_fields(self, monkeypatch) -> None:
        captured: dict = {}

        def fake_investigate(symptom: str) -> FakeReport:
            captured["symptom"] = symptom
            return FakeReport()

        monkeypatch.setattr(app_module, "_run_investigation", fake_investigate)

        status, _ = _post("/", json.dumps({"symptom": "Queue backlog"}).encode())
        assert status == 200
        assert captured["symptom"] == "Queue backlog"

    def test_failed_investigation_maps_to_failed_state(self, monkeypatch) -> None:
        monkeypatch.setattr(
            app_module,
            "_run_investigation",
            lambda symptom: FakeReport(status="timed_out"),
        )

        request = {"message": {"parts": [{"type": "text", "text": "Slow API"}]}}
        status, body = _post("/", json.dumps(request).encode())

        assert status == 200
        assert body["status"]["state"] == "failed"
        assert body["status"]["message"] == "timed_out"

    def test_invalid_json_returns_400(self) -> None:
        status, body = _post("/", b"{not json")
        assert status == 400
        assert "error" in body

    def test_missing_symptom_returns_400(self) -> None:
        status, body = _post("/", json.dumps({"message": {"parts": []}}).encode())
        assert status == 400
        assert "error" in body

    def test_post_to_unknown_path_still_404(self) -> None:
        status, _ = _post("/nope", b"{}")
        assert status == 404
