"""get_lambda_stats — Lambda metrics for the status-update queue's consumer."""

from datetime import datetime, timedelta, timezone

from ..aws_client import get_client
from ..resource_resolver import resolve_status_updater_function_name


def _functions_matching(needle: str) -> list[str]:
    """Return every function whose name contains *needle* (case-insensitive).

    Only used for a caller-supplied filter: it is the documented way to ask
    "every function whose name looks like this", and it needs a full listing.
    """
    lambda_client = get_client("lambda")
    paginator = lambda_client.get_paginator("list_functions")
    lowered = needle.lower()
    return [
        fn["FunctionName"]
        for page in paginator.paginate()
        for fn in page["Functions"]
        if lowered in fn["FunctionName"].lower()
    ]


def get_lambda_stats(minutes: int = 15, function_name: str | None = None) -> dict:
    """Return Lambda metrics (invocations, errors, duration, throttles).

    Args:
        minutes: Lookback window in minutes (default 15).
        function_name: Optional function name, or any substring of one, to
            filter on (matched case-insensitively). When omitted the
            status-updater is resolved at runtime: the queue URL comes from the
            ``/petstore/queueurl`` SSM parameter in the backend account, and the
            function is the one whose event source mapping consumes that queue
            (see ``src/resource_resolver.py``). The upstream generates the
            function's physical name at deploy time, so there is no literal to
            fall back to and an unresolvable function is an error rather than a
            guess.

    Returns:
        Dict with Lambda function metrics.

    Raises:
        ResourceResolutionError: if no function name was supplied and the
            consumer of the status-update queue could not be resolved.
    """
    if function_name:
        functions = _functions_matching(function_name)
    else:
        functions = [resolve_status_updater_function_name()]

    cw = get_client("cloudwatch")

    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=minutes)

    results = {}
    for fn_name in functions:
        metrics = {}
        for metric_name, stat in [
            ("Invocations", "Sum"),
            ("Errors", "Sum"),
            ("Duration", "Average"),
            ("Throttles", "Sum"),
        ]:
            response = cw.get_metric_statistics(
                Namespace="AWS/Lambda",
                MetricName=metric_name,
                Dimensions=[{"Name": "FunctionName", "Value": fn_name}],
                StartTime=start_time,
                EndTime=end_time,
                Period=minutes * 60,
                Statistics=[stat],
            )
            datapoints = response.get("Datapoints", [])
            if datapoints:
                # Take the most recent datapoint
                latest = sorted(datapoints, key=lambda d: d["Timestamp"])[-1]
                metrics[metric_name.lower()] = latest[stat]
            else:
                metrics[metric_name.lower()] = 0

        results[fn_name] = metrics

    return {
        "period_minutes": minutes,
        "functions": results,
    }
