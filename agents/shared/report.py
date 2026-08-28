"""Structured investigation report schema + S3 archival.

Fields: business_impact, root_cause (fault_id, confidence), evidence_timeline,
remediation, telemetry (round_trips, tokens, duration_seconds, tool_calls).
JSON-serializable; archived to S3.
"""

from __future__ import annotations

import json
import os
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.config import Config

_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Reports bucket. AgentsInfraStack creates `aiops-poc-reports-<ops-account>` and
# injects the name as REPORT_BUCKET, so the environment is the normal source.
#
# There is deliberately NO literal default. The old default `aiops-poc-reports`
# is a bucket that exists in no deployment — the real name is account-suffixed —
# and S3 bucket names are a single global namespace, so a put_object against an
# unsuffixed guess either fails or writes an incident report into a bucket
# somebody else owns. When the variable is absent the account is asked for its
# own identity instead, which is the one derivation that cannot be stale.
_BUCKET_PREFIX = "aiops-poc-reports"
_resolved_bucket: str | None = None

_boto_config = Config(
    region_name=_REGION,
    retries={"max_attempts": 2, "mode": "standard"},
)


def _resolve_report_bucket() -> str:
    """Return the reports bucket name: REPORT_BUCKET, else derived from STS.

    Cached for the process — the name cannot change while the runtime lives.
    """
    global _resolved_bucket

    configured = os.environ.get("REPORT_BUCKET", "").strip()
    if configured:
        return configured

    if _resolved_bucket is not None:
        return _resolved_bucket

    try:
        account = boto3.client("sts", config=_boto_config).get_caller_identity()[
            "Account"
        ]
    except Exception as exc:
        raise RuntimeError(
            "REPORT_BUCKET is not set and the account it would be derived from "
            f"could not be read ({type(exc).__name__}: {exc}). AgentsInfraStack "
            f"injects REPORT_BUCKET as {_BUCKET_PREFIX}-<ops-account-id>; set it "
            "explicitly, or pass archive_to_s3(bucket=...)."
        ) from exc

    _resolved_bucket = f"{_BUCKET_PREFIX}-{account}"
    return _resolved_bucket


@dataclass
class RootCause:
    fault_id: str
    confidence: str  # "high" | "medium" | "low"
    description: str = ""


@dataclass
class EvidenceItem:
    timestamp: str
    metric_name: str
    value: Any
    threshold: Any = None
    source: str = ""


@dataclass
class Telemetry:
    round_trips: int = 0
    tokens: int = 0
    duration_seconds: float = 0.0
    tool_calls: int = 0


@dataclass
class InvestigationReport:
    """Structured fallback-agent investigation report."""

    report_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    status: str = "completed"  # "completed" | "timed_out" | "error"
    trigger: str = ""
    skills_enabled: bool = True

    business_impact: str = ""
    root_cause: RootCause = field(default_factory=lambda: RootCause(fault_id="unknown", confidence="low"))
    evidence_timeline: list[EvidenceItem] = field(default_factory=list)
    remediation: list[str] = field(default_factory=list)
    telemetry: Telemetry = field(default_factory=Telemetry)

    def to_dict(self) -> dict:
        """Return a JSON-serializable dict."""
        return asdict(self)

    def to_json(self, indent: int = 2) -> str:
        """Serialize to JSON string."""
        return json.dumps(self.to_dict(), indent=indent, default=str)

    def archive_to_s3(self, bucket: str | None = None, s3_client: Any | None = None) -> str:
        """Archive the report to S3 and return the object key.

        Key format: reports/<YYYY-MM-DD>/<report_id>.json
        """
        bucket = bucket or _resolve_report_bucket()
        s3 = s3_client or boto3.client("s3", config=_boto_config)

        date_prefix = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        key = f"reports/{date_prefix}/{self.report_id}.json"

        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=self.to_json().encode("utf-8"),
            ContentType="application/json",
        )
        return key
