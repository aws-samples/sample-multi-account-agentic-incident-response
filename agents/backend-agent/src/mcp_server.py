"""MCP serving mode for the backend-devops-agent (PRIMARY protocol).

Wraps the Strands investigation agent behind a single MCP tool
(`investigate`) over stateless streamable HTTP, following the AgentCore
Runtime MCP contract (mirrors mcp-servers/backend-diagnostics/src/server.py):
bind 0.0.0.0:8000, path /mcp, stateless.

The A2A server (src/server.py, port 9000) is the ALTERNATE serving mode —
kept intact; src/__main__.py dispatches on SERVE_PROTOCOL.
"""

from __future__ import annotations

import json
from typing import Any

from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "Backend DevOps Agent",
    instructions=(
        "Fallback runbook-consultation agent for the PetAdoptions backend "
        "domain. Delegate here to check the documented runbooks/playbooks "
        "for a symptom: the `investigate` tool consults the runbook "
        "knowledge (Agent Skills) and returns the documented likely root "
        "causes, the verification steps the owning team should run, and "
        "documented remediation guidance. It has NO live telemetry — "
        "findings are documented knowledge, not observed fact. "
        "Consultation-only — never mutates anything."
    ),
    # AgentCore Runtime MCP contract: bind 0.0.0.0:8000, path /mcp, stateless
    # streamable HTTP (the platform generates Mcp-Session-Id headers and load
    # balances across microVMs, so the server must not track sessions).
    host="0.0.0.0",  # nosec B104  # AgentCore Runtime ingress requires the container to listen on 0.0.0.0; the port is not internet-facing and callers are authenticated with SigV4 at the data plane
    port=8000,
    streamable_http_path="/mcp",
    stateless_http=True,
)


async def _run_investigation(symptom: str) -> Any:
    """Run the backend agent investigation (lazy import for testability —
    importing .agent pulls in the Strands SDK)."""
    from .agent import run_investigation

    return await run_investigation(symptom)


@mcp.tool()
async def investigate(symptom: str) -> dict:
    """Consult the documented backend runbooks for an incident symptom.

    Checks the PetAdoptions backend runbook/playbook catalog (Agent
    Skills) — NO live telemetry; returns documented knowledge, not
    observed fact — for symptoms across ECS, Aurora, DynamoDB, SQS,
    and Lambda:

    - Backend runbook consultation: general backend service symptoms
      (ECS, Aurora, DynamoDB, SQS, Lambda).
    - Checkout latency: documented causes and checks for adoption
      checkout latency breaches in the payforadoption service path.
    - Search: documented causes and checks for petsearch failures and
      performance degradation backed by DynamoDB.
    - Payments failures: documented causes and checks for payment
      processing failures in the payforadoption -> Aurora path.
    - Fulfillment backlog: documented causes and checks for the
      SQS -> petstatusupdater -> DynamoDB async path.

    Returns which runbook(s) apply, the documented likely root causes,
    the verification steps the owning team should run, and documented
    remediation guidance. Runs up to 10 minutes (hard timeout, partial
    report on expiry). Consultation-only: never mutates anything.

    Args:
        symptom: The incident symptom or consultation request, e.g.
            "Checkout latency p99 above 2 seconds".

    Returns:
        dict with:
        - status: "completed" | "timed_out" | "error"
        - report: the structured consultation report (business impact,
          documented root cause with confidence, recommended checks,
          remediation guidance, telemetry).
    """
    report = await _run_investigation(symptom)
    return {"status": report.status, "report": json.loads(report.to_json())}


if __name__ == "__main__":
    # Host/port/path/statelessness are configured on the FastMCP instance
    # above — FastMCP.run() only accepts the transport.
    mcp.run(transport="streamable-http")
