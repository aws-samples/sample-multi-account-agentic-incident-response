"""BE-scoped boto3 read-only tool wrappers.

Each function assumes the `aiops-backend-domain-read` role in the Backend
account and executes a single read-only AWS API call. The account is never
written here: it comes from the `BE_ACCOUNT_ID` environment variable.

ALTERNATE / UNUSED: the fallback agents were descoped to knowledge-only, so
no deployed runtime imports this module and no stack injects BE_ACCOUNT_ID
for it. The module is kept for reference; calling it without supplying the
account fails cleanly instead of reaching a stale hardcoded one.
"""

from __future__ import annotations

import os
from typing import Any

import boto3
from botocore.config import Config

_BE_ROLE_NAME = os.environ.get("BE_ROLE_NAME", "aiops-backend-domain-read")
_REGION = os.environ.get("AWS_REGION", "us-east-1")

_boto_config = Config(
    region_name=_REGION,
    retries={"max_attempts": 2, "mode": "standard"},
)


def _be_account_id() -> str:
    """Return the Backend account ID from the environment.

    Read at call time, not import time, and with no fallback: this module is
    an unused alternate path, so nothing populates BE_ACCOUNT_ID for it and a
    caller that reaches here must supply it explicitly (Requirements 5.1-5.3).
    """
    value = os.environ.get("BE_ACCOUNT_ID", "").strip()
    if not value:
        raise RuntimeError(
            "BE_ACCOUNT_ID is not set. agents/shared/aws_tools is an unused "
            "alternate path since the knowledge-only descope, so no stack "
            "injects it; set it from config/accounts.json → backend.accountId "
            "to use these wrappers."
        )
    return value


def _assume_be_role_credentials() -> dict[str, str]:
    """Assume the BE read-only role and return temporary credentials."""
    sts = boto3.client("sts", config=_boto_config)
    response = sts.assume_role(
        RoleArn=f"arn:aws:iam::{_be_account_id()}:role/{_BE_ROLE_NAME}",
        RoleSessionName="aiops-shared-tools",
        DurationSeconds=900,
    )
    creds = response["Credentials"]
    return {
        "aws_access_key_id": creds["AccessKeyId"],
        "aws_secret_access_key": creds["SecretAccessKey"],
        "aws_session_token": creds["SessionToken"],
    }


def _be_client(service: str) -> Any:
    """Return a boto3 client for *service* using BE read-only credentials."""
    creds = _assume_be_role_credentials()
    return boto3.client(service, config=_boto_config, **creds)


# ---------------------------------------------------------------------------
# CloudWatch tools
# ---------------------------------------------------------------------------


def get_recent_alarms(state: str = "ALARM", max_results: int = 20) -> list[dict]:
    """Return recent CloudWatch alarms in the given state."""
    cw = _be_client("cloudwatch")
    response = cw.describe_alarms(StateValue=state, MaxRecords=max_results)
    return [
        {
            "name": a["AlarmName"],
            "state": a["StateValue"],
            "reason": a.get("StateReason", ""),
            "updated": a["StateUpdatedTimestamp"].isoformat(),
        }
        for a in response.get("MetricAlarms", [])
    ]


def get_metric_stats(
    namespace: str,
    metric_name: str,
    dimensions: list[dict[str, str]],
    stat: str = "p99",
    period: int = 60,
    minutes: int = 30,
) -> list[dict]:
    """Return metric datapoints for a given metric over *minutes*."""
    import datetime

    cw = _be_client("cloudwatch")
    end = datetime.datetime.now(datetime.timezone.utc)
    start = end - datetime.timedelta(minutes=minutes)
    response = cw.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric_name,
        Dimensions=[{"Name": k, "Value": v} for d in dimensions for k, v in d.items()],
        StartTime=start,
        EndTime=end,
        Period=period,
        Statistics=[stat] if stat in ("Average", "Sum", "Minimum", "Maximum", "SampleCount") else [],
        ExtendedStatistics=[stat] if stat.startswith("p") else [],
    )
    return [
        {"timestamp": dp["Timestamp"].isoformat(), "value": dp.get(stat) or dp.get("ExtendedStatistics", {}).get(stat)}
        for dp in response.get("Datapoints", [])
    ]


# ---------------------------------------------------------------------------
# ECS tools
# ---------------------------------------------------------------------------


def get_service_health(cluster: str, service: str) -> dict:
    """Return ECS service health summary."""
    ecs = _be_client("ecs")
    response = ecs.describe_services(cluster=cluster, services=[service])
    if not response.get("services"):
        return {"error": f"Service {service} not found in cluster {cluster}"}
    svc = response["services"][0]
    return {
        "service": svc["serviceName"],
        "status": svc["status"],
        "desired": svc["desiredCount"],
        "running": svc["runningCount"],
        "pending": svc["pendingCount"],
        "deployments": len(svc.get("deployments", [])),
        "events": [e["message"] for e in svc.get("events", [])[:5]],
    }


# ---------------------------------------------------------------------------
# DynamoDB tools
# ---------------------------------------------------------------------------


def get_dynamodb_health(table_name: str) -> dict:
    """Return DynamoDB table health summary."""
    ddb = _be_client("dynamodb")
    response = ddb.describe_table(TableName=table_name)
    table = response["Table"]
    return {
        "table": table["TableName"],
        "status": table["TableStatus"],
        "item_count": table.get("ItemCount", 0),
        "size_bytes": table.get("TableSizeBytes", 0),
        "provisioned": table.get("ProvisionedThroughput", {}),
    }


# ---------------------------------------------------------------------------
# SQS tools
# ---------------------------------------------------------------------------


def get_queue_stats(queue_url: str) -> dict:
    """Return SQS queue statistics."""
    sqs = _be_client("sqs")
    attrs = sqs.get_queue_attributes(
        QueueUrl=queue_url,
        AttributeNames=[
            "ApproximateNumberOfMessages",
            "ApproximateNumberOfMessagesNotVisible",
            "ApproximateNumberOfMessagesDelayed",
            "ApproximateAgeOfOldestMessage",
        ],
    )["Attributes"]
    return {
        "queue_url": queue_url,
        "messages_available": int(attrs.get("ApproximateNumberOfMessages", 0)),
        "messages_in_flight": int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0)),
        "messages_delayed": int(attrs.get("ApproximateNumberOfMessagesDelayed", 0)),
        "oldest_message_age_seconds": int(attrs.get("ApproximateAgeOfOldestMessage", 0)),
    }


# ---------------------------------------------------------------------------
# RDS tools
# ---------------------------------------------------------------------------


def get_db_health(db_identifier: str) -> dict:
    """Return RDS instance health summary."""
    rds = _be_client("rds")
    response = rds.describe_db_instances(DBInstanceIdentifier=db_identifier)
    if not response.get("DBInstances"):
        return {"error": f"DB instance {db_identifier} not found"}
    db = response["DBInstances"][0]
    return {
        "identifier": db["DBInstanceIdentifier"],
        "status": db["DBInstanceStatus"],
        "engine": db["Engine"],
        "engine_version": db["EngineVersion"],
        "instance_class": db["DBInstanceClass"],
        "multi_az": db.get("MultiAZ", False),
        "storage_gb": db.get("AllocatedStorage", 0),
    }


# ---------------------------------------------------------------------------
# Lambda tools
# ---------------------------------------------------------------------------


def get_lambda_stats(function_name: str) -> dict:
    """Return Lambda function configuration and recent invocation stats."""
    lam = _be_client("lambda")
    config = lam.get_function_configuration(FunctionName=function_name)
    return {
        "function": config["FunctionName"],
        "runtime": config.get("Runtime", ""),
        "memory_mb": config["MemorySize"],
        "timeout_s": config["Timeout"],
        "state": config.get("State", "Active"),
        "last_modified": config["LastModified"],
    }


# ---------------------------------------------------------------------------
# Synthetics (Canary) tools
# ---------------------------------------------------------------------------


def get_canary_results(canary_name: str) -> dict:
    """Return recent canary run results."""
    syn = _be_client("synthetics")
    response = syn.get_canary_runs(Name=canary_name, MaxResults=5)
    runs = response.get("CanaryRuns", [])
    return {
        "canary": canary_name,
        "runs": [
            {
                "status": r["Status"]["State"],
                "started": r["Timeline"]["Started"].isoformat() if r.get("Timeline", {}).get("Started") else None,
                "duration_ms": r.get("Timeline", {}).get("DurationInMilliseconds"),
            }
            for r in runs
        ],
    }
