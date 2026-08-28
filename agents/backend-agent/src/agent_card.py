"""Agent card definition for the backend-devops-agent (A2A ALTERNATE mode).

Skill descriptions reflect the knowledge-only descope (runbook consultation,
no live telemetry) so the alternate stays coherent with the MCP primary.

Serves the agent card at /.well-known/agent-card.json satisfying the
DevOps Agent remote-agent registration required fields:
- name (non-empty string)
- description (string)
- supportedInterfaces (array)
- capabilities (object)
- skills (array)
"""

from __future__ import annotations

from .config import AGENT_DESCRIPTION, AGENT_NAME, A2A_PORT


def get_agent_card() -> dict:
    """Return the agent card as a dict satisfying DevOps Agent requirements."""
    return {
        "name": AGENT_NAME,
        "description": AGENT_DESCRIPTION,
        "url": f"http://localhost:{A2A_PORT}",
        "version": "0.1.0",
        "supportedInterfaces": [
            {
                "type": "a2a",
                "version": "1.0",
                "endpoint": f"http://localhost:{A2A_PORT}",
            }
        ],
        "capabilities": {
            "investigation": True,
            "remediation": False,
            "streaming": False,
            "pushNotifications": False,
        },
        "skills": [
            {
                "id": "backend-runbook-consultation",
                "name": "Backend Runbook Consultation",
                "description": (
                    "Consults documented runbooks for PetAdoptions backend "
                    "service symptoms (ECS, Aurora, DynamoDB, SQS, Lambda) — "
                    "returns documented causes and checks, no live telemetry."
                ),
            },
            {
                "id": "checkout-latency-consultation",
                "name": "Checkout Latency Runbook Consultation",
                "description": (
                    "Documented causes, checks, and remediation guidance for "
                    "adoption checkout latency breaches in the payforadoption "
                    "service path."
                ),
            },
            {
                "id": "search-consultation",
                "name": "Search Runbook Consultation",
                "description": (
                    "Documented causes, checks, and remediation guidance for "
                    "petsearch failures and performance degradation backed by "
                    "DynamoDB."
                ),
            },
            {
                "id": "payments-failure-consultation",
                "name": "Payments Failure Runbook Consultation",
                "description": (
                    "Documented causes, checks, and remediation guidance for "
                    "payment processing failures in the payforadoption → "
                    "Aurora path."
                ),
            },
            {
                "id": "fulfillment-backlog-consultation",
                "name": "Fulfillment Backlog Runbook Consultation",
                "description": (
                    "Documented causes, checks, and remediation guidance for "
                    "adoption fulfillment backlog issues in the SQS → "
                    "petstatusupdater → DynamoDB async path."
                ),
            },
        ],
    }
