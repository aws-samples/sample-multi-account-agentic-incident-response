"""get_dynamodb_health — DynamoDB table metrics for PetAdoptions tables."""

from datetime import datetime, timedelta, timezone

from ..aws_client import get_client
from ..resource_resolver import resolve_adoptions_table


def get_dynamodb_health(table_name: str | None = None) -> dict:
    """Return DynamoDB metrics (consumed capacity, throttled requests, item count).

    Args:
        table_name: Optional specific table. When omitted the adoptions table is
            resolved from the ``/petstore/dynamodbtablename`` SSM parameter in
            the backend account (see ``src/resource_resolver.py``) — the
            upstream generates the table's physical name at deploy time, so
            there is no literal to fall back to and an unresolvable table is an
            error rather than a guess.

    Returns:
        Dict with DynamoDB table health details.

    Raises:
        ResourceResolutionError: if no table name was supplied and the SSM
            parameter could not be read.
    """
    tables_to_check = [table_name] if table_name else [resolve_adoptions_table()]

    dynamodb = get_client("dynamodb")
    cw = get_client("cloudwatch")

    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=15)

    results = {}
    for tbl in tables_to_check:
        # Get table description for item count and status
        try:
            desc = dynamodb.describe_table(TableName=tbl)["Table"]
            table_info = {
                "status": desc.get("TableStatus"),
                "item_count": desc.get("ItemCount", 0),
                "size_bytes": desc.get("TableSizeBytes", 0),
            }
        except Exception as e:
            results[tbl] = {"error": str(e)}
            continue

        # Get CloudWatch metrics for the table
        metrics_data = {}
        for metric_name, stat in [
            ("ConsumedReadCapacityUnits", "Sum"),
            ("ConsumedWriteCapacityUnits", "Sum"),
            ("ReadThrottleEvents", "Sum"),
            ("WriteThrottleEvents", "Sum"),
        ]:
            response = cw.get_metric_statistics(
                Namespace="AWS/DynamoDB",
                MetricName=metric_name,
                Dimensions=[{"Name": "TableName", "Value": tbl}],
                StartTime=start_time,
                EndTime=end_time,
                Period=900,
                Statistics=[stat],
            )
            datapoints = response.get("Datapoints", [])
            if datapoints:
                latest = sorted(datapoints, key=lambda d: d["Timestamp"])[-1]
                metrics_data[metric_name] = latest[stat]
            else:
                metrics_data[metric_name] = 0

        results[tbl] = {
            **table_info,
            "consumed_read_capacity": metrics_data.get("ConsumedReadCapacityUnits", 0),
            "consumed_write_capacity": metrics_data.get("ConsumedWriteCapacityUnits", 0),
            "read_throttle_events": metrics_data.get("ReadThrottleEvents", 0),
            "write_throttle_events": metrics_data.get("WriteThrottleEvents", 0),
        }

    return {"tables": results}
