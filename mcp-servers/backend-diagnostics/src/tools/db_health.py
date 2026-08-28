"""get_db_health — RDS/Aurora metrics for PetAdoptions PostgreSQL cluster."""

from datetime import datetime, timedelta, timezone

from ..aws_client import get_client
from ..resource_resolver import ResourceResolutionError, resolve_rds_cluster_id


def get_db_health(cluster_id: str | None = None) -> dict:
    """Return RDS/Aurora metrics (connections, CPU, latency, deadlocks).

    Args:
        cluster_id: Optional Aurora cluster identifier **or** writer/reader
            endpoint hostname (the identifier is the endpoint's first label).
            When omitted the identifier is resolved from the
            ``/petstore/rds-writer-endpoint`` SSM parameter in the backend
            account (see ``src/resource_resolver.py``) — the upstream generates
            the cluster's identifier at deploy time, so there is no literal to
            fall back to.

            A caller-supplied hostname that cannot carry the identifier (a
            custom or instance endpoint) is reported as an error in the result
            rather than guessed at.

    Returns:
        Dict with database cluster health details.
    """
    if cluster_id:
        # A value the caller chose: report why it is unusable in the result,
        # next to the value itself, rather than raising at them.
        try:
            resolved_cluster_id = resolve_rds_cluster_id(cluster_id)
        except ResourceResolutionError as e:
            return {"cluster_id": cluster_id, "error": str(e)}
    else:
        # Nothing supplied: a failed lookup is a hard failure, never a guess.
        resolved_cluster_id = resolve_rds_cluster_id()

    rds = get_client("rds")
    cw = get_client("cloudwatch")

    # Get cluster status
    try:
        clusters = rds.describe_db_clusters(DBClusterIdentifier=resolved_cluster_id)
        cluster = clusters["DBClusters"][0]
        cluster_info = {
            "status": cluster.get("Status"),
            "engine": cluster.get("Engine"),
            "engine_version": cluster.get("EngineVersion"),
            "members": len(cluster.get("DBClusterMembers", [])),
            "multi_az": cluster.get("MultiAZ", False),
        }
    except Exception as e:
        return {"cluster_id": resolved_cluster_id, "error": str(e)}

    # Get CloudWatch metrics
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=15)

    metrics_data = {}
    metric_definitions = [
        ("DatabaseConnections", "Average"),
        ("CPUUtilization", "Average"),
        ("ReadLatency", "Average"),
        ("WriteLatency", "Average"),
        ("Deadlocks", "Sum"),
        ("FreeableMemory", "Average"),
        ("BufferCacheHitRatio", "Average"),
    ]

    for metric_name, stat in metric_definitions:
        response = cw.get_metric_statistics(
            Namespace="AWS/RDS",
            MetricName=metric_name,
            Dimensions=[
                {"Name": "DBClusterIdentifier", "Value": resolved_cluster_id}
            ],
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

    return {
        "cluster_id": resolved_cluster_id,
        **cluster_info,
        "metrics": {
            "database_connections": metrics_data.get("DatabaseConnections", 0),
            "cpu_utilization_percent": metrics_data.get("CPUUtilization", 0),
            "read_latency_seconds": metrics_data.get("ReadLatency", 0),
            "write_latency_seconds": metrics_data.get("WriteLatency", 0),
            "deadlocks": metrics_data.get("Deadlocks", 0),
            "freeable_memory_bytes": metrics_data.get("FreeableMemory", 0),
            "buffer_cache_hit_ratio": metrics_data.get("BufferCacheHitRatio", 0),
        },
    }
