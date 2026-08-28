"""Backend KB Agent — Strands agent with Bedrock KB retrieval.

Knowledge comes from Bedrock Knowledge Base (architecture docs corpus), NOT
from skills. MUST cite retrieved KB passages in responses.

Knowledge-only (telemetry descoped, 2026-07): the DevOps Agent is the
live-telemetry layer; this agent is a KB-grounded documentation checker.
Its only tools are kb_retrieve and escalate_to_owner_team — the shared
aws_tools telemetry wrappers were removed.
Investigation-only, 10-min timeout.
"""

from __future__ import annotations

import logging
import os
import signal
import sys
from typing import Any

# Add shared module to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "shared"))

from strands import Agent, tool
from strands.models.bedrock import BedrockModel

from agents.shared.instrumentation import instrumentation_context
from agents.shared.report import (
    InvestigationReport,
    Telemetry,
)

from .escalation_tool import escalate_to_owner_team
from .kb_retrieval_tool import kb_retrieve

_TIMEOUT_SECONDS = int(os.environ.get("INVESTIGATION_TIMEOUT", "600"))  # 10 min
# Cross-region inference profile ID — the bare foundation-model ID and the
# sonnet-4 profile are rejected (invalid / provider-marked Legacy) in this account.
_MODEL_ID = os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Escalation steering: "always" is a demo-reliability setting — the agent
# escalates every investigation so the owning-team email reliably arrives
# during demos. "auto" softens this to escalate only on probable root cause
# or low confidence. Read at agent-creation (module import) time.
_ESCALATION_MODE = os.environ.get("ESCALATION_MODE", "always").strip().lower()


def _build_system_prompt(escalation_mode: str) -> str:
    """Build the system prompt with escalation rules per ESCALATION_MODE."""
    if escalation_mode == "auto":
        escalation_rule = (
            "8. Escalate to the service-owning team via escalate_to_owner_team "
            "when you identify a probable root cause or cannot reach confidence"
        )
        escalation_step = (
            "5. If you identified a probable root cause or cannot reach "
            "confidence, call escalate_to_owner_team once with your summary"
        )
    else:  # "always" — demo-eager default
        escalation_rule = (
            "8. CRITICAL: after consulting the documentation and forming your "
            "findings, you MUST call escalate_to_owner_team exactly once with "
            "your summary BEFORE producing the final report — this notifies "
            "the service-owning team. Never skip it, even when confidence is "
            "low or no root cause was found (in that case escalate what was "
            "checked and mark it inconclusive)"
        )
        escalation_step = (
            "5. Call escalate_to_owner_team exactly once with your summary, "
            "root cause (or inconclusive note), evidence, and KB citations — "
            "MANDATORY before the final report"
        )

    return f"""\
You are the backend-kb-agent, a KB-grounded documentation checker for the
PetAdoptions e-commerce platform. Your knowledge comes from retrieving
architecture and scenario documentation via the Knowledge Base — you MUST
use the kb_retrieve tool to ground every finding in documented facts. You
have NO live AWS access: your findings are documentation-grounded
hypotheses, never observed fact.

## Your role
- Check the documentation when the first responder delegates a symptom
- Correlate the symptom with documented request paths and failure patterns
- Produce documentation-grounded findings with KB citations, including the
  documented checks the owning team should perform to verify
- Escalate findings to the service-owning team (human notification via SNS)

## Critical rules
1. ALWAYS retrieve relevant architecture/scenario context from the KB first
2. CITE which KB documents you used (include source names in kb_citations)
3. You have NO live AWS access — you cannot check metrics, service health,
   or resource state. State every finding as a documented hypothesis and
   list the checks the owning team should run to verify it
4. You are investigation-only — do NOT suggest or perform remediation actions
   beyond what the documentation records (escalate_to_owner_team is the sole
   action exception: it only notifies humans)
5. Do NOT read /aiops-poc/active-scenario (that is demo bookkeeping)
6. Focus on business impact, not raw infrastructure metrics
7. If the documentation cannot pin a likely root cause, say so
{escalation_rule}

## Investigation approach
1. Use kb_retrieve to pull the architecture/scenario docs for the symptom
2. Correlate the symptom with documented patterns and request paths
3. Form findings citing KB sources: documented likely root cause with a
   confidence level
4. List the documented checks the owning team should perform to verify
   (you cannot run them yourself)
{escalation_step}
6. Produce the final report

## Available tools
- kb_retrieve: Search the architecture knowledge base (ALWAYS use first)
- escalate_to_owner_team: Notify the service-owning team of your findings
  via SNS email (call once per investigation, after consulting the docs)

## Report format
Your final answer MUST be a structured JSON report with:
- business_impact: what the customer experiences
- root_cause: {{ fault_id, confidence (high/medium/low), description }} —
  a documentation-grounded hypothesis, not observed fact
- recommended_checks: documented verification steps for the owning team
- kb_citations: list of KB source document names used
- remediation: documented remediation guidance (observation only)
- escalation: {{ sent: bool, message_id: str|null }} — whether
  escalate_to_owner_team was called and the SNS MessageId it returned
"""


SYSTEM_PROMPT = _build_system_prompt(_ESCALATION_MODE)


# Knowledge-only toolset: the shared aws_tools telemetry wrappers
# (alarms, metrics, service/DB/queue/Lambda/canary health) were removed in
# the 2026-07 descope — the DevOps Agent is the live-telemetry layer.
@tool
def tool_escalate_to_owner_team(
    summary: str, root_cause: str, evidence: str, kb_citations: str
) -> str:
    """Notify the service-owning team of your investigation findings via SNS email.

    Call this once per investigation after evidence gathering, before the
    final report. It publishes a readable escalation email to the owning-team
    topic — human notification only, it cannot mutate anything.

    Args:
        summary: Business-impact summary (first ~80 chars become the subject).
        root_cause: Root cause description, or why it is inconclusive.
        evidence: Evidence and investigation summary.
        kb_citations: KB source document names used (comma-separated).

    Returns:
        Confirmation with the SNS MessageId, or an error explanation.
    """
    return escalate_to_owner_team(summary, root_cause, evidence, kb_citations)


@tool
def tool_kb_retrieve(query: str, max_results: int = 5) -> str:
    """Search the PetAdoptions architecture knowledge base.

    Use this tool FIRST to retrieve architecture documentation, investigation
    procedures, and service topology information. Always cite the sources
    returned in your investigation report.
    """
    return kb_retrieve(query, max_results)


def create_agent() -> Agent:
    """Create the KB agent with all tools configured."""
    model = BedrockModel(
        model_id=_MODEL_ID,
        region_name=_REGION,
    )

    agent = Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=[
            tool_kb_retrieve,
            tool_escalate_to_owner_team,
        ],
    )

    return agent


def investigate(symptom: str) -> InvestigationReport:
    """Run a full investigation and return a structured report.

    Enforces the 10-minute timeout. Returns a partial report on timeout.
    """
    report = InvestigationReport(
        trigger=symptom,
        skills_enabled=False,  # KB agent does not use skills
    )

    with instrumentation_context() as ctx:
        agent = create_agent()

        # Set timeout
        def _timeout_handler(signum: int, frame: Any) -> None:
            raise TimeoutError("Investigation timed out")

        old_handler = signal.signal(signal.SIGALRM, _timeout_handler)
        signal.alarm(_TIMEOUT_SECONDS)

        try:
            prompt = (
                f"Investigate this business symptom: {symptom}\n\n"
                "Follow the investigation approach: retrieve KB context first, "
                "correlate the symptom with documented patterns, and produce "
                "the report with the documented likely root cause and the "
                "checks the owning team should run. "
                "Include kb_citations in your response."
            )

            result = agent(prompt)
            response_text = str(result)

            # Parse structured response from agent
            report.status = "completed"
            report.business_impact = symptom
            # The agent's response contains the analysis
            # In production, we'd parse the structured JSON from the response

        except TimeoutError:
            # Log so runtime (CloudWatch) logs capture the timeout — otherwise
            # it is only visible inside the returned report.
            logging.getLogger(__name__).exception(
                "Investigation timed out after %s seconds", _TIMEOUT_SECONDS
            )
            report.status = "timed_out"
            report.root_cause.confidence = "low"
            report.root_cause.description = "Investigation timed out before completion"

        except Exception as e:
            # Log so runtime (CloudWatch) logs capture the failure — otherwise
            # the exception is silently swallowed into the report.
            logging.getLogger(__name__).exception("Investigation failed")
            report.status = "error"
            report.root_cause.description = f"Investigation error: {str(e)}"

        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old_handler)

            report.telemetry = Telemetry(
                round_trips=ctx.round_trips,
                tokens=ctx.tokens,
                duration_seconds=round(ctx.duration_seconds, 2),
                tool_calls=ctx.tool_calls,
            )

    # Archive to S3, exactly as the devops agent does. AgentsInfraStack injects
    # REPORT_BUCKET into this runtime and grants the shared
    # `aiops-poc-agent-task-role` write on that bucket, so the archive was
    # always intended — this agent simply never made the call, which meant
    # "did a fallback agent produce a report?" answered differently depending
    # on which of the two agents happened to be delegated to.
    #
    # Best-effort, and the exception is LOGGED rather than swallowed so a real
    # permission failure is visible in the runtime logs instead of looking
    # identical to never having tried.
    try:
        report.archive_to_s3()
    except Exception:
        logging.getLogger(__name__).exception(
            "Failed to archive report %s to S3; the report is still returned "
            "to the caller",
            report.report_id,
        )

    return report
