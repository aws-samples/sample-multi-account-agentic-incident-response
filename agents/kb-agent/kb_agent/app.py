"""ASGI application for the backend-kb-agent.

Exposes:
- GET /.well-known/agent-card.json — A2A agent card
- POST / — A2A task endpoint (investigation requests)
- GET /ping — health check (AgentCore Runtime A2A contract)
- GET /health — health check (legacy alias)
"""

from __future__ import annotations

import json
import logging
import os
import uuid
from typing import Any, Callable

logger = logging.getLogger(__name__)

_PORT = int(os.environ.get("A2A_PORT", "9000"))


async def health_check(scope: dict, receive: Callable, send: Callable) -> None:
    """Simple health check endpoint."""
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"application/json")],
    })
    await send({
        "type": "http.response.body",
        "body": json.dumps({"status": "healthy", "agent": "backend-kb-agent"}).encode(),
    })


async def agent_card_handler(scope: dict, receive: Callable, send: Callable) -> None:
    """Serve the agent card."""
    from .agent_card import AGENT_CARD

    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"application/json")],
    })
    await send({
        "type": "http.response.body",
        "body": json.dumps(AGENT_CARD, indent=2).encode(),
    })


async def _send_json(send: Callable, status: int, payload: dict) -> None:
    """Send a JSON response over the ASGI interface."""
    await send({
        "type": "http.response.start",
        "status": status,
        "headers": [(b"content-type", b"application/json")],
    })
    await send({
        "type": "http.response.body",
        "body": json.dumps(payload).encode(),
    })


async def _read_body(receive: Callable) -> bytes:
    """Read the full request body from the ASGI receive channel."""
    body = b""
    more_body = True
    while more_body:
        message = await receive()
        body += message.get("body", b"")
        more_body = message.get("more_body", False)
    return body


def _extract_symptom(body: dict[str, Any]) -> str | None:
    """Extract investigation symptom from an A2A task request body."""
    # A2A format: {"message": {"parts": [{"type": "text", "text": "..."}]}}
    message = body.get("message", {})
    if isinstance(message, dict):
        for part in message.get("parts", []):
            if part.get("type") == "text" and part.get("text"):
                return part["text"]

    # Fallback: look for a direct "text" or "symptom" field
    if body.get("text"):
        return body["text"]
    if body.get("symptom"):
        return body["symptom"]

    # Fallback: top-level message as a plain string
    if isinstance(message, str) and message:
        return message

    return None


def _run_investigation(symptom: str) -> Any:
    """Run the KB agent investigation (indirection for testability)."""
    from .agent import investigate

    return investigate(symptom)


async def task_handler(scope: dict, receive: Callable, send: Callable) -> None:
    """Handle A2A task requests (investigation requests) at POST /.

    Expects a JSON body with at minimum:
    - message.parts[0].text: the investigation symptom/request

    Returns the investigation report in the A2A task-result format.
    """
    raw_body = await _read_body(receive)
    try:
        body = json.loads(raw_body) if raw_body else {}
    except json.JSONDecodeError:
        await _send_json(send, 400, {"error": "Invalid JSON body"})
        return

    symptom = _extract_symptom(body)
    if not symptom:
        await _send_json(
            send, 400, {"error": "No investigation symptom provided in message"}
        )
        return

    task_id = body.get("id", str(uuid.uuid4()))
    logger.info(f"Starting investigation task {task_id}: {symptom[:100]}")

    report = _run_investigation(symptom)

    response = {
        "id": task_id,
        "status": {
            "state": "completed" if report.status == "completed" else "failed",
            "message": report.status,
        },
        "artifacts": [
            {
                "name": "investigation-report",
                "parts": [
                    {
                        "type": "text",
                        "text": report.to_json(),
                    }
                ],
            }
        ],
    }

    await _send_json(send, 200, response)


async def app(scope: dict, receive: Callable, send: Callable) -> None:
    """ASGI application handling routing."""
    if scope["type"] != "http":
        return

    path = scope.get("path", "")
    method = scope.get("method", "GET")

    if path in ("/ping", "/health") and method == "GET":
        await health_check(scope, receive, send)
    elif path == "/.well-known/agent-card.json" and method == "GET":
        await agent_card_handler(scope, receive, send)
    elif path == "/" and method == "POST":
        await task_handler(scope, receive, send)
    else:
        await _send_json(send, 404, {"error": "Not found"})


def run() -> None:
    """Run the ASGI server."""
    import uvicorn

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    logger.info(f"Starting backend-kb-agent on port {_PORT}")
    uvicorn.run(app, host="0.0.0.0", port=_PORT)  # nosec B104  # AgentCore Runtime ingress requires the container to listen on 0.0.0.0; the port is not internet-facing and callers are authenticated with SigV4 at the data plane


if __name__ == "__main__":
    run()
