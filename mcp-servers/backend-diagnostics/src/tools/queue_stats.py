"""get_queue_stats — SQS queue metrics for the pet status update queue."""

from datetime import datetime, timedelta, timezone

from ..aws_client import get_client
from ..resource_resolver import resolve_status_update_queue


def get_queue_stats(queue_name: str | None = None) -> dict:
    """Return SQS queue metrics (messages visible, in-flight, age of oldest).

    Args:
        queue_name: Optional queue name **or** full queue URL. When omitted the
            queue is resolved from the ``/petstore/queueurl`` SSM parameter in
            the backend account (see ``src/resource_resolver.py``) — the
            upstream generates the queue's physical name at deploy time, so
            there is no literal to fall back to and an unresolvable queue is an
            error rather than a guess.

    Returns:
        Dict with queue health metrics.

    Raises:
        ResourceResolutionError: if no queue name was supplied and the SSM
            parameter could not be read.
    """
    queue_url, resolved_name = resolve_status_update_queue(queue_name)

    sqs = get_client("sqs")
    response = sqs.get_queue_attributes(
        QueueUrl=queue_url,
        AttributeNames=[
            "ApproximateNumberOfMessages",
            "ApproximateNumberOfMessagesNotVisible",
            "ApproximateNumberOfMessagesDelayed",
        ],
    )

    attrs = response.get("Attributes", {})

    # Also get the age-of-oldest-message from CloudWatch
    cw = get_client("cloudwatch")
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=5)

    age_response = cw.get_metric_statistics(
        Namespace="AWS/SQS",
        MetricName="ApproximateAgeOfOldestMessage",
        Dimensions=[{"Name": "QueueName", "Value": resolved_name}],
        StartTime=start_time,
        EndTime=end_time,
        Period=60,
        Statistics=["Maximum"],
    )

    age_datapoints = age_response.get("Datapoints", [])
    age_seconds = 0
    if age_datapoints:
        latest = sorted(age_datapoints, key=lambda d: d["Timestamp"])[-1]
        age_seconds = latest.get("Maximum", 0)

    return {
        "queue_name": resolved_name,
        "messages_visible": int(attrs.get("ApproximateNumberOfMessages", 0)),
        "messages_in_flight": int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0)),
        "messages_delayed": int(attrs.get("ApproximateNumberOfMessagesDelayed", 0)),
        "age_of_oldest_message_seconds": age_seconds,
    }
