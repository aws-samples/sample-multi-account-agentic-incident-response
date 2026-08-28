"""MCP serving mode for the backend-kb-agent (PRIMARY protocol).

Wraps the KB-grounded Strands investigation agent behind a single MCP tool
(`investigate`) over stateless streamable HTTP, following the AgentCore
Runtime MCP contract (mirrors mcp-servers/backend-diagnostics/src/server.py):
bind 0.0.0.0:8000, path /mcp, stateless.

The A2A app (kb_agent/app.py, port 9000) is the ALTERNATE serving mode —
kept intact; kb_agent/__main__.py dispatches on SERVE_PROTOCOL.
"""

from __future__ import annotations

import json
from typing import Any

from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "Backend KB Agent",
    instructions=(
        "Fallback KB-grounded consultation agent for the PetAdoptions "
        "backend domain. Knowledge comes from Bedrock Knowledge Base "
        "retrieval over the architecture/scenario corpus — every finding "
        "is grounded in retrieved documentation and cites its sources. "
        "It has NO live telemetry: it returns documented likely root "
        "causes and the checks the owning team should run, then escalates "
        "a summary to the owning team via SNS email. Delegate here when "
        "documented-architecture grounding is wanted. Consultation-only — "
        "the SNS escalation (human notification) is its only action."
    ),
    # AgentCore Runtime MCP contract: bind 0.0.0.0:8000, path /mcp, stateless
    # streamable HTTP (the platform generates Mcp-Session-Id headers and load
    # balances across microVMs, so the server must not track sessions).
    host="0.0.0.0",  # nosec B104  # AgentCore Runtime ingress requires the container to listen on 0.0.0.0; the port is not internet-facing and callers are authenticated with SigV4 at the data plane
    port=8000,
    streamable_http_path="/mcp",
    stateless_http=True,
)


def _investigate(question: str) -> Any:
    """Run the KB agent investigation (lazy import for testability —
    importing .agent pulls in the Strands SDK)."""
    from .agent import investigate as kb_investigate

    return kb_investigate(question)


@mcp.tool()
def investigate(question: str) -> dict:
    """Run a KB-grounded documentation consultation for an incident symptom.

    Checks the Bedrock Knowledge Base architecture corpus (architecture
    docs and agent-safe scenario knowledge) for the symptom, citing
    retrieved passages — NO live telemetry; findings are documented
    hypotheses, not observed fact:

    - KB-grounded consultation: backend service symptoms across ECS,
      Aurora, DynamoDB, SQS, and Lambda with architecture context.
    - Checkout latency analysis: documented causes and checks for slow
      adoption checkout (payforadoption -> Aurora path).
    - Search availability analysis: documented causes and checks for
      search failures or degradation (petsearch -> DynamoDB path).
    - Status lag analysis: documented causes and checks for adoption
      status update delays (SQS -> petstatusupdater -> DynamoDB async
      path).
    - Payments failure analysis: documented causes and checks for
      adoption/payment failures (payforadoption errors or crashes).

    Returns the documented likely root cause with KB citations plus the
    verification checks the owning team should run, and escalates a
    summary to the owning team via SNS email. Runs up to 10 minutes
    (hard timeout, partial report on expiry). Consultation-only: the SNS
    escalation (human notification) is its only action — it never
    mutates workload resources.

    Args:
        question: The incident symptom or consultation question, e.g.
            "Adoption status updates lag by 15 minutes".

    Returns:
        dict with:
        - status: "completed" | "timed_out" | "error"
        - report: the structured consultation report (business impact,
          documented root cause with confidence, recommended checks,
          KB citations, remediation guidance, escalation status,
          telemetry).
    """
    report = _investigate(question)
    return {"status": report.status, "report": json.loads(report.to_json())}


if __name__ == "__main__":
    # Host/port/path/statelessness are configured on the FastMCP instance
    # above — FastMCP.run() only accepts the transport.
    mcp.run(transport="streamable-http")
