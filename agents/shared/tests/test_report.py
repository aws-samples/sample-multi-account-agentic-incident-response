"""Unit tests for report module."""

import json
import re
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from agents.shared import report
from agents.shared.report import (
    EvidenceItem,
    InvestigationReport,
    RootCause,
    Telemetry,
)


class TestInvestigationReport:
    def test_default_report_is_json_serializable(self):
        report = InvestigationReport()
        json_str = report.to_json()
        parsed = json.loads(json_str)

        assert parsed["status"] == "completed"
        assert parsed["root_cause"]["fault_id"] == "unknown"
        assert parsed["telemetry"]["tool_calls"] == 0

    def test_report_with_all_fields(self):
        report = InvestigationReport(
            trigger="checkout-latency-alarm",
            skills_enabled=True,
            business_impact="Adoption checkouts taking >5s (p99), affecting ~200 users",
            root_cause=RootCause(
                fault_id="db-overload",
                confidence="high",
                description="Aurora CPU at 98%, blocking sessions detected",
            ),
            evidence_timeline=[
                EvidenceItem(
                    timestamp="2024-01-15T10:30:00Z",
                    metric_name="payforadoption/latency_p99",
                    value=5200,
                    threshold=2000,
                    source="CloudWatch",
                ),
            ],
            remediation=["Scale down load generator", "Kill blocking sessions"],
            telemetry=Telemetry(
                round_trips=3,
                tokens=4500,
                duration_seconds=45.2,
                tool_calls=7,
            ),
        )

        data = report.to_dict()
        assert data["root_cause"]["fault_id"] == "db-overload"
        assert data["root_cause"]["confidence"] == "high"
        assert len(data["evidence_timeline"]) == 1
        assert data["evidence_timeline"][0]["value"] == 5200
        assert data["telemetry"]["tool_calls"] == 7
        assert data["telemetry"]["tokens"] == 4500

    def test_to_json_roundtrip(self):
        report = InvestigationReport(
            business_impact="Test impact",
            root_cause=RootCause(fault_id="test", confidence="medium"),
        )
        json_str = report.to_json()
        parsed = json.loads(json_str)
        assert parsed["business_impact"] == "Test impact"

    def test_archive_to_s3(self):
        mock_s3 = MagicMock()
        report = InvestigationReport(
            report_id="test-report-123",
            business_impact="Test",
        )

        key = report.archive_to_s3(bucket="test-bucket", s3_client=mock_s3)

        assert "test-report-123.json" in key
        assert key.startswith("reports/")
        mock_s3.put_object.assert_called_once()
        call_kwargs = mock_s3.put_object.call_args[1]
        assert call_kwargs["Bucket"] == "test-bucket"
        assert call_kwargs["ContentType"] == "application/json"

    def test_report_id_is_unique(self):
        r1 = InvestigationReport()
        r2 = InvestigationReport()
        assert r1.report_id != r2.report_id


class TestReportBucketResolution:
    """The reports bucket has no literal default.

    `AgentsInfraStack` creates `aiops-poc-reports-<ops-account>` and injects the
    name. The old unsuffixed default named a bucket that exists in no deployment,
    and S3 bucket names are one global namespace, so a wrong guess either fails
    or writes an incident report into somebody else's bucket.
    """

    def test_environment_variable_wins(self, monkeypatch):
        monkeypatch.setenv("REPORT_BUCKET", "aiops-poc-reports-111111111111")
        assert (
            report._resolve_report_bucket() == "aiops-poc-reports-111111111111"
        )

    def test_missing_variable_derives_the_name_from_the_caller_account(
        self, monkeypatch
    ):
        monkeypatch.delenv("REPORT_BUCKET", raising=False)
        monkeypatch.setattr(report, "_resolved_bucket", None)
        sts = MagicMock()
        sts.get_caller_identity.return_value = {"Account": "333333333333"}
        with patch.object(report.boto3, "client", return_value=sts):
            assert (
                report._resolve_report_bucket() == "aiops-poc-reports-333333333333"
            )

    def test_derived_name_is_cached(self, monkeypatch):
        monkeypatch.delenv("REPORT_BUCKET", raising=False)
        monkeypatch.setattr(report, "_resolved_bucket", None)
        sts = MagicMock()
        sts.get_caller_identity.return_value = {"Account": "333333333333"}
        with patch.object(report.boto3, "client", return_value=sts) as mock_client:
            report._resolve_report_bucket()
            report._resolve_report_bucket()
        assert mock_client.call_count == 1

    def test_unresolvable_account_fails_naming_the_variable_and_the_shape(
        self, monkeypatch
    ):
        monkeypatch.delenv("REPORT_BUCKET", raising=False)
        monkeypatch.setattr(report, "_resolved_bucket", None)
        with patch.object(
            report.boto3, "client", side_effect=RuntimeError("no credentials")
        ):
            with pytest.raises(RuntimeError) as excinfo:
                report._resolve_report_bucket()
        message = str(excinfo.value)
        assert "REPORT_BUCKET" in message
        assert "aiops-poc-reports-<ops-account-id>" in message

    def test_blank_variable_is_treated_as_unset(self, monkeypatch):
        monkeypatch.setenv("REPORT_BUCKET", "   ")
        monkeypatch.setattr(report, "_resolved_bucket", None)
        sts = MagicMock()
        sts.get_caller_identity.return_value = {"Account": "333333333333"}
        with patch.object(report.boto3, "client", return_value=sts):
            assert (
                report._resolve_report_bucket() == "aiops-poc-reports-333333333333"
            )

    def test_source_carries_no_unsuffixed_bucket_default(self):
        """`os.environ.get("REPORT_BUCKET", "")` is fine; a name is not."""
        source = Path(report.__file__).read_text()
        assert (
            re.search(r'environ\.get\(\s*"REPORT_BUCKET"\s*,\s*"[^"]+"', source)
            is None
        ), "the reports bucket must have no literal default"
