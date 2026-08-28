"""A2A Server for the backend-kb-agent.

Serves the agent card at /.well-known/agent-card.json and handles A2A task
requests on port 9000.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

import uvicorn
from strands.agent.a2a import A2AServer

from .agent import create_agent, investigate
from .agent_card import AGENT_CARD

logger = logging.getLogger(__name__)

_PORT = int(os.environ.get("A2A_PORT", "9000"))
_HOST = os.environ.get("A2A_HOST", "0.0.0.0")  # nosec B104  # AgentCore Runtime ingress requires the container to listen on 0.0.0.0; the port is not internet-facing and callers are authenticated with SigV4 at the data plane


def create_a2a_server() -> A2AServer:
    """Create and configure the A2A server."""
    agent = create_agent()
    server = A2AServer(agent=agent, port=_PORT, host=_HOST)
    return server


def run() -> None:
    """Start the A2A server."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    logger.info(f"Starting backend-kb-agent A2A server on {_HOST}:{_PORT}")
    server = create_a2a_server()
    server.run()


if __name__ == "__main__":
    run()
