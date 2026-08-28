"""Tests for get_db_health tool."""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

from src.config import REGION
from src.resource_resolver import ResourceResolutionError
from src.tools.db_health import get_db_health

# Same shape as the CloudFormation-generated Aurora identifier, no real value.
RESOLVED_CLUSTER_ID = "devstoragestack-auroradatabase-sy1th3t1cabc"


def _stub_clients(mock_get_client, datapoints=None):
    """Wire mock rds + cloudwatch clients with a healthy cluster."""
    mock_rds = MagicMock()
    mock_cw = MagicMock()
    mock_get_client.side_effect = [mock_rds, mock_cw]
    mock_rds.describe_db_clusters.return_value = {
        "DBClusters": [
            {
                "Status": "available",
                "Engine": "aurora-postgresql",
                "EngineVersion": "15.4",
                "DBClusterMembers": [],
                "MultiAZ": False,
            }
        ]
    }
    mock_cw.get_metric_statistics.return_value = {"Datapoints": datapoints or []}
    return mock_rds, mock_cw


def _dimension_values(mock_cw):
    """Return every DBClusterIdentifier dimension the CloudWatch calls used."""
    values = set()
    for c in mock_cw.get_metric_statistics.call_args_list:
        for dim in c.kwargs["Dimensions"]:
            if dim["Name"] == "DBClusterIdentifier":
                values.add(dim["Value"])
    return values


@patch("src.tools.db_health.resolve_rds_cluster_id")
@patch("src.tools.db_health.get_client")
def test_get_db_health_success(mock_get_client, mock_resolve):
    """Test DB health returns cluster info and metrics."""
    mock_resolve.return_value = RESOLVED_CLUSTER_ID
    mock_rds = MagicMock()
    mock_cw = MagicMock()
    mock_get_client.side_effect = [mock_rds, mock_cw]

    mock_rds.describe_db_clusters.return_value = {
        "DBClusters": [
            {
                "Status": "available",
                "Engine": "aurora-postgresql",
                "EngineVersion": "15.4",
                "DBClusterMembers": [{"DBInstanceIdentifier": "instance-1"}],
                "MultiAZ": True,
            }
        ]
    }

    ts = datetime(2025, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
    mock_cw.get_metric_statistics.return_value = {
        "Datapoints": [{"Timestamp": ts, "Average": 45.0, "Sum": 3.0}]
    }

    result = get_db_health()

    assert result["cluster_id"] == RESOLVED_CLUSTER_ID
    assert result["status"] == "available"
    assert result["engine"] == "aurora-postgresql"
    assert result["members"] == 1
    assert result["multi_az"] is True
    assert result["metrics"]["database_connections"] == 45.0


@patch("src.tools.db_health.resolve_rds_cluster_id")
@patch("src.tools.db_health.get_client")
def test_get_db_health_cluster_not_found(mock_get_client, mock_resolve):
    """Test DB health handles cluster not found."""
    mock_resolve.return_value = RESOLVED_CLUSTER_ID
    mock_rds, _ = _stub_clients(mock_get_client)
    mock_rds.describe_db_clusters.side_effect = Exception("DBClusterNotFoundFault")

    result = get_db_health()

    assert result["cluster_id"] == RESOLVED_CLUSTER_ID
    assert "error" in result


@patch("src.tools.db_health.resolve_rds_cluster_id")
@patch("src.tools.db_health.get_client")
def test_get_db_health_no_metric_data(mock_get_client, mock_resolve):
    """Test DB health handles empty metric data gracefully."""
    mock_resolve.return_value = RESOLVED_CLUSTER_ID
    _stub_clients(mock_get_client)

    result = get_db_health()

    assert result["metrics"]["database_connections"] == 0
    assert result["metrics"]["cpu_utilization_percent"] == 0
    assert result["metrics"]["deadlocks"] == 0


@patch("src.tools.db_health.resolve_rds_cluster_id")
@patch("src.tools.db_health.get_client")
def test_get_db_health_default_uses_resolved_cluster(mock_get_client, mock_resolve):
    """Omitting cluster_id inspects the cluster the resolver reports."""
    mock_resolve.return_value = RESOLVED_CLUSTER_ID
    mock_rds, mock_cw = _stub_clients(mock_get_client)

    result = get_db_health()

    mock_resolve.assert_called_once_with()
    assert (
        mock_rds.describe_db_clusters.call_args.kwargs["DBClusterIdentifier"]
        == RESOLVED_CLUSTER_ID
    )
    assert _dimension_values(mock_cw) == {RESOLVED_CLUSTER_ID}
    assert result["cluster_id"] == RESOLVED_CLUSTER_ID


@patch("src.tools.db_health.get_client")
def test_get_db_health_accepts_cluster_identifier(mock_get_client):
    """A caller-supplied identifier reaches both the RDS call and the CW dimension."""
    mock_rds, mock_cw = _stub_clients(mock_get_client)

    result = get_db_health(RESOLVED_CLUSTER_ID)

    assert (
        mock_rds.describe_db_clusters.call_args.kwargs["DBClusterIdentifier"]
        == RESOLVED_CLUSTER_ID
    )
    assert _dimension_values(mock_cw) == {RESOLVED_CLUSTER_ID}
    assert result["cluster_id"] == RESOLVED_CLUSTER_ID


@patch("src.tools.db_health.get_client")
def test_get_db_health_accepts_writer_endpoint(mock_get_client):
    """A /petstore/rds-writer-endpoint value yields the cluster's first label."""
    mock_rds, mock_cw = _stub_clients(mock_get_client)
    endpoint = (
        f"{RESOLVED_CLUSTER_ID}.cluster-c9xmpl.{REGION}.rds.amazonaws.com"
    )

    result = get_db_health(endpoint)

    assert (
        mock_rds.describe_db_clusters.call_args.kwargs["DBClusterIdentifier"]
        == RESOLVED_CLUSTER_ID
    )
    assert _dimension_values(mock_cw) == {RESOLVED_CLUSTER_ID}
    assert result["cluster_id"] == RESOLVED_CLUSTER_ID


@patch("src.tools.db_health.get_client")
def test_get_db_health_accepts_reader_endpoint(mock_get_client):
    """The reader endpoint carries the same identifier in its first label."""
    _stub_clients(mock_get_client)
    endpoint = (
        f"{RESOLVED_CLUSTER_ID}.cluster-ro-c9xmpl.{REGION}.rds.amazonaws.com"
    )

    result = get_db_health(endpoint)

    assert result["cluster_id"] == RESOLVED_CLUSTER_ID


@patch("src.tools.db_health.get_client")
def test_get_db_health_rejects_endpoint_without_the_identifier(mock_get_client):
    """A custom endpoint does not carry the identifier, so it is not guessed at."""
    mock_rds, _ = _stub_clients(mock_get_client)
    endpoint = f"myreports.cluster-custom-c9xmpl.{REGION}.rds.amazonaws.com"

    result = get_db_health(endpoint)

    assert "error" in result
    assert result["cluster_id"] == endpoint
    mock_rds.describe_db_clusters.assert_not_called()


@patch("src.tools.db_health.resolve_rds_cluster_id")
@patch("src.tools.db_health.get_client")
def test_get_db_health_propagates_resolution_failure(mock_get_client, mock_resolve):
    """An unresolvable cluster is an error, never a fallback to a stale literal."""
    mock_resolve.side_effect = ResourceResolutionError("nope")

    with pytest.raises(ResourceResolutionError):
        get_db_health()

    mock_get_client.assert_not_called()
