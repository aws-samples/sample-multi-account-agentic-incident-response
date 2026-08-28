"""Unit tests for the SNS escalation tool with mocked boto3.

Never calls AWS: the SNS client is injected or boto3 is patched.
"""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add the kb-agent package to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from kb_agent.escalation_tool import (
    _build_message,
    _build_subject,
    escalate_to_owner_team,
)

# Canonical OPS Placeholder_Account_Id — the escalation topic lives in the
# monitoring account. The value is only ever compared against itself here, so it
# carries no meaning beyond ARN shape (Requirements 6.1, 6.5).
_TOPIC_ARN = "arn:aws:sns:us-east-1:333333333333:aiops-poc-escalations"


class TestEscalateToOwnerTeam:
    """Publish path with mocked SNS client."""

    def _mock_sns(self, message_id: str = "msg-abc-123") -> MagicMock:
        client = MagicMock()
        client.publish.return_value = {"MessageId": message_id}
        return client

    def test_publishes_to_topic_arn_from_env(self, monkeypatch) -> None:
        monkeypatch.setenv("ESCALATION_TOPIC_ARN", _TOPIC_ARN)
        client = self._mock_sns()

        result = escalate_to_owner_team(
            "Checkout latency above SLO",
            "Aurora blocking sessions",
            "p99 3.4s; blocking sessions high",
            "petadoptions-architecture.md",
            sns_client=client,
        )

        client.publish.assert_called_once()
        kwargs = client.publish.call_args.kwargs
        assert kwargs["TopicArn"] == _TOPIC_ARN
        assert "msg-abc-123" in result
        assert "Escalation sent" in result

    def test_message_contains_all_sections_and_footer(self, monkeypatch) -> None:
        monkeypatch.setenv("ESCALATION_TOPIC_ARN", _TOPIC_ARN)
        client = self._mock_sns()

        escalate_to_owner_team(
            "Checkout latency above SLO",
            "Aurora blocking sessions",
            "p99 3.4s over 30 min",
            "petadoptions-architecture.md, checkout-latency-scenario.md",
            sns_client=client,
        )

        message = client.publish.call_args.kwargs["Message"]
        assert "Business impact" in message
        assert "Root cause" in message
        assert "Evidence & investigation summary" in message
        assert "KB sources" in message
        assert "backend-kb-agent" in message  # footer attribution
        assert "AWS DevOps Agent chain" in message
        assert "Checkout latency above SLO" in message
        assert "Aurora blocking sessions" in message
        assert "checkout-latency-scenario.md" in message

    def test_subject_has_prefix_and_truncates(self, monkeypatch) -> None:
        monkeypatch.setenv("ESCALATION_TOPIC_ARN", _TOPIC_ARN)
        client = self._mock_sns()

        long_summary = "x" * 200
        escalate_to_owner_team(long_summary, "rc", "ev", "cit", sns_client=client)

        subject = client.publish.call_args.kwargs["Subject"]
        assert subject.startswith("[AI-Ops PoC] Escalation: ")
        assert len(subject) <= 100  # SNS hard limit
        assert "\n" not in subject

    def test_unset_env_returns_error_string(self, monkeypatch) -> None:
        monkeypatch.delenv("ESCALATION_TOPIC_ARN", raising=False)

        result = escalate_to_owner_team("s", "r", "e", "c")

        assert "NOT sent" in result
        assert "ESCALATION_TOPIC_ARN" in result

    def test_publish_failure_returns_error_string(self, monkeypatch) -> None:
        monkeypatch.setenv("ESCALATION_TOPIC_ARN", _TOPIC_ARN)
        client = MagicMock()
        client.publish.side_effect = Exception("AuthorizationError")

        result = escalate_to_owner_team("s", "r", "e", "c", sns_client=client)

        assert "NOT sent" in result
        assert "AuthorizationError" in result

    def test_creates_boto3_client_when_not_injected(self, monkeypatch) -> None:
        monkeypatch.setenv("ESCALATION_TOPIC_ARN", _TOPIC_ARN)
        mock_client = self._mock_sns("msg-boto3")

        with patch("kb_agent.escalation_tool.boto3") as mock_boto:
            mock_boto.client.return_value = mock_client
            result = escalate_to_owner_team("s", "r", "e", "c")

        mock_boto.client.assert_called_once()
        assert mock_boto.client.call_args.args[0] == "sns"
        assert "msg-boto3" in result


class TestBuilders:
    """Subject/message builder edge cases."""

    def test_subject_uses_first_line_only(self) -> None:
        subject = _build_subject("first line\nsecond line")
        assert "second line" not in subject
        assert "first line" in subject

    def test_empty_fields_get_placeholders(self) -> None:
        message = _build_message("", "", "", "")
        assert "(not provided)" in message
        assert "(not determined)" in message
        assert "(none cited)" in message
