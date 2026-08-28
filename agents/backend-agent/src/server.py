"""A2A Server for the backend-devops-agent.

Exposes:
- GET /.well-known/agent-card.json — agent card
- GET /ping — health check (AgentCore Runtime A2A contract)
- POST / — A2A task endpoint (investigation requests)

Uses Starlette for the HTTP layer + uvicorn for serving.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from typing import Any

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .agent import run_investigation
from .agent_card import get_agent_card
from .config import A2A_HOST, A2A_PORT

logger = logging.getLogger(__name__)


async def agent_card_endpoint(request: Request) -> JSONResponse:
    """Serve the agent card at /.well-known/agent-card.json."""
    return JSONResponse(get_agent_card())


async def ping_endpoint(request: Request) -> JSONResponse:
    """Health check endpoint required by the AgentCore Runtime A2A contract."""
    return JSONResponse({"status": "healthy"})


async def task_endpoint(request: Request) -> JSONResponse:
    """Handle A2A task requests (investigation requests).

    Expects a JSON body with at minimum:
    - message.parts[0].text: the investigation symptom/request

    Returns a JSON response with the investigation report.
    """
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(
            {"error": "Invalid JSON body"},
            status_code=400,
        )

    # Extract the symptom from the A2A message format
    symptom = _extract_symptom(body)
    if not symptom:
        return JSONResponse(
            {"error": "No investigation symptom provided in message"},
            status_code=400,
        )

    task_id = body.get("id", str(uuid.uuid4()))
    logger.info(f"Starting investigation task {task_id}: {symptom[:100]}")

    # Run the investigation
    report = await run_investigation(symptom)

    # Format response in A2A task result format
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

    return JSONResponse(response)


def _extract_symptom(body: dict[str, Any]) -> str | None:
    """Extract investigation symptom from A2A task request body."""
    # A2A format: {"message": {"parts": [{"type": "text", "text": "..."}]}}
    message = body.get("message", {})
    parts = message.get("parts", [])
    for part in parts:
        if part.get("type") == "text" and part.get("text"):
            return part["text"]

    # Fallback: look for a direct "text" or "symptom" field
    if body.get("text"):
        return body["text"]
    if body.get("symptom"):
        return body["symptom"]

    # Fallback: try top-level message as string
    if isinstance(message, str):
        return message

    return None


# Starlette application
app = Starlette(
    routes=[
        Route("/.well-known/agent-card.json", agent_card_endpoint, methods=["GET"]),
        Route("/ping", ping_endpoint, methods=["GET"]),
        Route("/", task_endpoint, methods=["POST"]),
    ],
)


def run_server() -> None:
    """Start the A2A server on the configured host and port."""
    import uvicorn

    logger.info(f"Starting backend-devops-agent A2A server on {A2A_HOST}:{A2A_PORT}")
    uvicorn.run(app, host=A2A_HOST, port=A2A_PORT, log_level="info")
