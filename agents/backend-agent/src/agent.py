"""Backend DevOps Agent — Strands runbook-consultation agent with timeout.

Creates the Strands agent instance with the runbook-consultation system
prompt (knowledge = Agent Skills). Telemetry tools are descoped: the DevOps
Agent is the live-telemetry layer; this fallback is a knowledge checker
(src/tools.py is kept on disk as the ALTERNATE, unused).
Handles the 10-minute hard timeout, producing a partial report on expiry.
"""

from __future__ import annotations

import asyncio
import logging
import sys
from pathlib import Path
from typing import Any

from strands import Agent

_agents_dir = Path(__file__).resolve().parent.parent.parent.parent
if str(_agents_dir) not in sys.path:
    sys.path.insert(0, str(_agents_dir))

from agents.shared.instrumentation import InstrumentationContext, instrumentation_context  # noqa: E402
from agents.shared.report import (  # noqa: E402
    InvestigationReport,
    RootCause,
    Telemetry,
)

from .config import INVESTIGATION_TIMEOUT_SECONDS  # noqa: E402
from .prompt import build_system_prompt  # noqa: E402

# NOTE: telemetry tools (src/tools.py, ALL_TOOLS) are deliberately NOT wired
# in — the agent is knowledge-only (runbook consultation via Agent Skills).


def create_agent() -> Agent:
    """Create and return the backend-devops-agent Strands agent instance.

    Knowledge-only: no tools are registered — the agent answers from the
    runbook/playbook skills embedded in the system prompt.
    """
    system_prompt = build_system_prompt()
    agent = Agent(
        system_prompt=system_prompt,
        tools=[],
    )
    return agent


async def run_investigation(symptom: str) -> InvestigationReport:
    """Run an investigation for the given symptom with timeout.

    Returns a structured InvestigationReport. If the investigation exceeds
    the hard timeout (10 min), returns a partial report with status=timed_out.
    """
    with instrumentation_context() as ctx:
        try:
            report = await asyncio.wait_for(
                _execute_investigation(symptom, ctx),
                timeout=INVESTIGATION_TIMEOUT_SECONDS,
            )
        except asyncio.TimeoutError:
            report = InvestigationReport(
                status="timed_out",
                trigger=symptom,
                business_impact="Investigation timed out before completion",
                root_cause=RootCause(
                    fault_id="unknown",
                    confidence="low",
                    description="Investigation exceeded 10-minute timeout",
                ),
                telemetry=Telemetry(**ctx.to_telemetry_dict()),
            )
        except Exception as e:
            report = InvestigationReport(
                status="error",
                trigger=symptom,
                business_impact=f"Investigation failed: {str(e)}",
                root_cause=RootCause(
                    fault_id="unknown",
                    confidence="low",
                    description=f"Error during investigation: {str(e)}",
                ),
                telemetry=Telemetry(**ctx.to_telemetry_dict()),
            )

    # Archive to S3. Best-effort — a failed archive must not lose the report,
    # which is still returned to the caller over MCP.
    #
    # The exception is LOGGED rather than swallowed. `except Exception: pass`
    # made a real failure (a missing s3:PutObject grant, a bucket name that
    # resolved wrong) indistinguishable from an agent that never attempted the
    # archive at all, which is exactly the ambiguity that made the smoke test's
    # S3 check unreadable.
    try:
        report.archive_to_s3()
    except Exception:
        logging.getLogger(__name__).exception(
            "Failed to archive report %s to S3; the report is still returned "
            "to the caller",
            report.report_id,
        )

    return report


async def _execute_investigation(
    symptom: str, ctx: InstrumentationContext
) -> InvestigationReport:
    """Execute the actual investigation using the Strands agent."""
    agent = create_agent()

    investigation_prompt = (
        f"Consult the runbooks for this incident symptom: {symptom}\n\n"
        "Answer from documented runbook knowledge only (no live checks). "
        "Produce a structured consultation report. Include:\n"
        "1. Which runbook(s) apply\n"
        "2. Business impact assessment (as documented)\n"
        "3. Documented likely root cause with confidence level\n"
        "4. Recommended checks — the documented verification steps the "
        "owning team should run\n"
        "5. Documented remediation guidance\n"
    )

    # Run the agent synchronously (Strands agents are sync)
    result = await asyncio.to_thread(agent, investigation_prompt)
    ctx.record_round_trip()

    # Parse agent output into structured report
    report = _parse_agent_response(result, symptom, ctx)
    return report


def _parse_agent_response(
    result: Any, trigger: str, ctx: InstrumentationContext
) -> InvestigationReport:
    """Parse the Strands agent response into a structured report.

    The agent is instructed to return structured information, but we handle
    cases where it returns free-form text as well.
    """
    # Extract text from agent result
    response_text = str(result) if result else "No response from agent"

    # Build report from agent output
    # The agent output is textual; we create a structured report with what we have
    report = InvestigationReport(
        status="completed",
        trigger=trigger,
        skills_enabled=True,
        business_impact=_extract_section(response_text, "business impact", response_text[:200]),
        root_cause=_extract_root_cause(response_text),
        remediation=_extract_remediation(response_text),
        telemetry=Telemetry(**ctx.to_telemetry_dict()),
    )
    return report


def _extract_section(text: str, section_name: str, default: str = "") -> str:
    """Extract a named section from the agent's text response."""
    lower = text.lower()
    idx = lower.find(section_name)
    if idx == -1:
        return default
    # Get text after the section header, up to the next section or 500 chars
    start = text.index("\n", idx) + 1 if "\n" in text[idx:] else idx + len(section_name)
    end = min(start + 500, len(text))
    return text[start:end].strip()[:500]


def _extract_root_cause(text: str) -> RootCause:
    """Extract root cause information from agent text."""
    lower = text.lower()

    # Try to find confidence
    confidence = "medium"
    if "high confidence" in lower or "confidence: high" in lower:
        confidence = "high"
    elif "low confidence" in lower or "confidence: low" in lower:
        confidence = "low"

    # Try to find fault id
    fault_id = "unknown"
    known_faults = [
        "checkout-degraded", "payments-error", "payments-crash",
        "db-overload", "ddb-throttle", "status-consumer-off",
        "search-crash", "ui-no-scale",
    ]
    for fault in known_faults:
        if fault in lower:
            fault_id = fault
            break

    # Extract description
    description = _extract_section(text, "root cause", text[:300])

    return RootCause(fault_id=fault_id, confidence=confidence, description=description)


def _extract_remediation(text: str) -> list[str]:
    """Extract remediation steps from agent text."""
    lower = text.lower()
    idx = lower.find("remediation")
    if idx == -1:
        idx = lower.find("recommendation")
    if idx == -1:
        return ["Review the investigation findings and take appropriate action."]

    # Get text after remediation header
    section = text[idx:idx + 500]
    lines = section.split("\n")[1:]  # Skip the header line
    steps = []
    for line in lines:
        stripped = line.strip().lstrip("0123456789.-) ")
        if stripped and not stripped.startswith("#"):
            steps.append(stripped[:200])
        if len(steps) >= 5:
            break

    return steps if steps else ["Review the investigation findings and take appropriate action."]
