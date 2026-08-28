"""SNS escalation tool for the KB agent.

Publishes an investigation summary to the aiops-poc-escalations SNS topic so
a human on the service-owning team receives an email. This is the single
deliberate write-scope action of the otherwise read-only fallback agents:
it can only notify humans and cannot mutate any workload resource.

Topic ARN comes from the ESCALATION_TOPIC_ARN env var (set by agents/infra);
the email subscription address is a config variable in config/accounts.json
(ops.escalationEmail).
"""

from __future__ import annotations

import os
from typing import Any

import boto3
from botocore.config import Config

# SNS enforces a 100-character, single-line subject — keep the first ~80
# chars of the summary, capped so prefix + summary never exceed the limit.
_SUBJECT_PREFIX = "[AI-Ops PoC] Escalation: "
_SUBJECT_MAX = 100  # SNS hard limit
_SUBJECT_SUMMARY_CHARS = min(80, _SUBJECT_MAX - len(_SUBJECT_PREFIX))


def _build_subject(summary: str) -> str:
    """Single-line subject: prefix + first ~80 chars of the summary."""
    first_line = summary.strip().splitlines()[0] if summary.strip() else "(no summary)"
    if len(first_line) > _SUBJECT_SUMMARY_CHARS:
        first_line = first_line[: _SUBJECT_SUMMARY_CHARS - 1] + "…"
    return _SUBJECT_PREFIX + first_line


def _build_message(
    summary: str, root_cause: str, evidence: str, kb_citations: str
) -> str:
    """Readable plain-text email body with clearly separated sections."""
    return (
        "AI-Ops PoC — investigation escalation\n"
        "=====================================\n"
        "\n"
        "Business impact\n"
        "---------------\n"
        f"{summary.strip() or '(not provided)'}\n"
        "\n"
        "Root cause\n"
        "----------\n"
        f"{root_cause.strip() or '(not determined)'}\n"
        "\n"
        "Evidence & investigation summary\n"
        "--------------------------------\n"
        f"{evidence.strip() or '(not provided)'}\n"
        "\n"
        "KB sources\n"
        "----------\n"
        f"{kb_citations.strip() or '(none cited)'}\n"
        "\n"
        "--\n"
        "Sent by the backend-kb-agent fallback (investigation-only) via the\n"
        "AWS DevOps Agent chain. Escalation is human-notification only — the\n"
        "agent cannot mutate workloads.\n"
    )


def escalate_to_owner_team(
    summary: str,
    root_cause: str,
    evidence: str,
    kb_citations: str,
    sns_client: Any | None = None,
) -> str:
    """Publish an investigation escalation to the owning-team SNS topic.

    Args:
        summary: Business-impact summary (first ~80 chars become the subject).
        root_cause: Root cause description (or why it is inconclusive).
        evidence: Evidence and investigation summary.
        kb_citations: KB source document names used in the investigation.
        sns_client: Optional pre-configured client (for testing).

    Returns:
        Short confirmation string including the SNS MessageId, or an
        explanatory error string if the topic is not configured / publish
        fails (never raises).
    """
    topic_arn = os.environ.get("ESCALATION_TOPIC_ARN", "")
    if not topic_arn:
        return (
            "Escalation NOT sent: ESCALATION_TOPIC_ARN is not configured for "
            "this runtime. Note this in the final report."
        )

    region = os.environ.get("AWS_REGION", "us-east-1")
    client = sns_client or boto3.client(
        "sns",
        config=Config(region_name=region, retries={"max_attempts": 2, "mode": "standard"}),
    )

    try:
        response = client.publish(
            TopicArn=topic_arn,
            Subject=_build_subject(summary),
            Message=_build_message(summary, root_cause, evidence, kb_citations),
        )
    except Exception as e:  # surface as text — the agent relays it
        return f"Escalation NOT sent: SNS publish failed: {e}"

    message_id = response.get("MessageId", "unknown")
    return (
        "Escalation sent to the service-owning team "
        f"(SNS MessageId: {message_id})."
    )
