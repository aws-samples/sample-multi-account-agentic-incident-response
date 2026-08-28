"""BE toolset — Strands tool wrappers over agents/shared/aws_tools.

════════════════════════════════════════════════════════════════════════
 ALTERNATE / UNUSED (telemetry descoped, 2026-07).

 The fallback agents were descoped to knowledge-only: the DevOps Agent is
 the live-telemetry layer, this agent is a runbook-consultation checker.
 Nothing imports ALL_TOOLS anymore (src/agent.py creates the agent with
 tools=[]); this module is kept on disk for reference, in line with the
 project's annotate-don't-delete convention (see the A2A ALTERNATE headers
 in scripts/).
════════════════════════════════════════════════════════════════════════

Exposes the shared read-only AWS tools as Strands-compatible tool functions
that can be registered with the agent. Each tool is investigation-only.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from strands import tool

# Add the agents directory to path so we can import from shared
_agents_dir = Path(__file__).resolve().parent.parent.parent.parent
if str(_agents_dir) not in sys.path:
    sys.path.insert(0, str(_agents_dir))

from agents.shared.aws_tools import (  # noqa: E402
    get_canary_results as _get_canary_results,
    get_db_health as _get_db_health,
    get_dynamodb_health as _get_dynamodb_health,
    get_lambda_stats as _get_lambda_stats,
    get_metric_stats as _get_metric_stats,
    get_queue_stats as _get_queue_stats,
    get_recent_alarms as _get_recent_alarms,
    get_service_health as _get_service_health,
)
from agents.shared.instrumentation import get_current_context  # noqa: E402


def _track() -> None:
    """Increment tool call counter if an instrumentation context is active."""
    ctx = get_current_context()
    if ctx:
        ctx.record_tool_call()


@tool
def get_service_health(cluster: str, service: str) -> dict[str, Any]:
    """Get ECS service health for a PetAdoptions backend service.

    Returns running/desired task counts, deployment status, and recent events.

    Args:
        cluster: ECS cluster name
        service: ECS service name (e.g. petsearch, payforadoption)
    """
    _track()
    return _get_service_health(cluster=cluster, service=service)


@tool
def get_metric_stats(
    namespace: str,
    metric_name: str,
    dimensions: list[dict[str, str]],
    stat: str = "p99",
    period: int = 60,
    minutes: int = 30,
) -> list[dict[str, Any]]:
    """Get CloudWatch metric statistics for a given metric.

    Returns datapoints with timestamp and value over the specified window.

    Args:
        namespace: CloudWatch namespace (e.g. AWS/ECS, AWS/RDS)
        metric_name: Metric name (e.g. CPUUtilization, Duration)
        dimensions: List of dimension dicts like [{"Name": "Value"}]
        stat: Statistic type (p99, Average, Sum, etc.)
        period: Period in seconds
        minutes: Lookback window in minutes
    """
    _track()
    return _get_metric_stats(
        namespace=namespace,
        metric_name=metric_name,
        dimensions=dimensions,
        stat=stat,
        period=period,
        minutes=minutes,
    )


@tool
def get_recent_alarms(state: str = "ALARM", max_results: int = 20) -> list[dict[str, Any]]:
    """Get recent CloudWatch alarms in the given state.

    Returns alarm names, states, reasons, and timestamps.

    Args:
        state: Alarm state filter (ALARM, OK, INSUFFICIENT_DATA)
        max_results: Maximum number of alarms to return
    """
    _track()
    return _get_recent_alarms(state=state, max_results=max_results)


@tool
def get_queue_stats(queue_url: str) -> dict[str, Any]:
    """Get SQS queue statistics.

    Returns message counts and age of the oldest message (business lag indicator).

    Args:
        queue_url: Full SQS queue URL
    """
    _track()
    return _get_queue_stats(queue_url=queue_url)


@tool
def get_dynamodb_health(table_name: str) -> dict[str, Any]:
    """Get DynamoDB table health summary.

    Returns table status, item count, size, and provisioned throughput.

    Args:
        table_name: DynamoDB table name
    """
    _track()
    return _get_dynamodb_health(table_name=table_name)


@tool
def get_db_health(db_identifier: str) -> dict[str, Any]:
    """Get RDS/Aurora instance health summary.

    Returns status, engine info, instance class, and storage.

    Args:
        db_identifier: RDS instance or cluster identifier
    """
    _track()
    return _get_db_health(db_identifier=db_identifier)


@tool
def get_lambda_stats(function_name: str) -> dict[str, Any]:
    """Get Lambda function configuration and stats.

    Returns runtime, memory, timeout, state, and last modified time.

    Args:
        function_name: Lambda function name
    """
    _track()
    return _get_lambda_stats(function_name=function_name)


@tool
def get_canary_results(canary_name: str) -> dict[str, Any]:
    """Get CloudWatch Synthetics canary run results.

    Returns recent run statuses, start times, and durations.

    Args:
        canary_name: Synthetics canary name
    """
    _track()
    return _get_canary_results(canary_name=canary_name)


# Collect all tools for agent registration
ALL_TOOLS = [
    get_service_health,
    get_metric_stats,
    get_recent_alarms,
    get_queue_stats,
    get_dynamodb_health,
    get_db_health,
    get_lambda_stats,
    get_canary_results,
]
