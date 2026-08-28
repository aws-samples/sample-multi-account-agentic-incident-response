"""Tests for get_dynamodb_health tool."""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

from src.resource_resolver import ResourceResolutionError
from src.tools.dynamodb_health import get_dynamodb_health

# Same shape as the CloudFormation-generated table name, no real value.
RESOLVED_TABLE = "DevStorageStack-DynamoDbddbPetadoption-Sy1Th3T1cAbc"


@patch("src.tools.dynamodb_health.resolve_adoptions_table")
@patch("src.tools.dynamodb_health.get_client")
def test_get_dynamodb_health_uses_resolved_table(mock_get_client, mock_resolve):
    """Omitting table_name inspects the table the resolver reports."""
    mock_resolve.return_value = RESOLVED_TABLE
    mock_ddb = MagicMock()
    mock_cw = MagicMock()
    mock_get_client.side_effect = [mock_ddb, mock_cw]

    mock_ddb.describe_table.return_value = {
        "Table": {
            "TableStatus": "ACTIVE",
            "ItemCount": 1500,
            "TableSizeBytes": 2048000,
        }
    }

    ts = datetime(2025, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
    mock_cw.get_metric_statistics.return_value = {
        "Datapoints": [{"Timestamp": ts, "Sum": 50.0}]
    }

    result = get_dynamodb_health()

    mock_resolve.assert_called_once_with()
    assert mock_ddb.describe_table.call_args.kwargs["TableName"] == RESOLVED_TABLE
    tbl = result["tables"][RESOLVED_TABLE]
    assert tbl["status"] == "ACTIVE"
    assert tbl["item_count"] == 1500
    assert tbl["consumed_read_capacity"] == 50.0


@patch("src.tools.dynamodb_health.resolve_adoptions_table")
@patch("src.tools.dynamodb_health.get_client")
def test_get_dynamodb_health_single_table(mock_get_client, mock_resolve):
    """A caller-supplied table wins outright — the resolver is never consulted."""
    mock_ddb = MagicMock()
    mock_cw = MagicMock()
    mock_get_client.side_effect = [mock_ddb, mock_cw]

    mock_ddb.describe_table.return_value = {
        "Table": {
            "TableStatus": "ACTIVE",
            "ItemCount": 200,
            "TableSizeBytes": 102400,
        }
    }

    mock_cw.get_metric_statistics.return_value = {"Datapoints": []}

    result = get_dynamodb_health("PetSearch")

    mock_resolve.assert_not_called()
    assert "PetSearch" in result["tables"]
    assert result["tables"]["PetSearch"]["read_throttle_events"] == 0


@patch("src.tools.dynamodb_health.get_client")
def test_get_dynamodb_health_table_error(mock_get_client):
    """Test DynamoDB health handles table describe errors."""
    mock_ddb = MagicMock()
    mock_cw = MagicMock()
    mock_get_client.side_effect = [mock_ddb, mock_cw]

    mock_ddb.describe_table.side_effect = Exception("Table not found")

    result = get_dynamodb_health("BadTable")

    assert "error" in result["tables"]["BadTable"]


@patch("src.tools.dynamodb_health.resolve_adoptions_table")
@patch("src.tools.dynamodb_health.get_client")
def test_get_dynamodb_health_propagates_resolution_failure(
    mock_get_client, mock_resolve
):
    """An unresolvable table is an error, never a fallback to a stale literal."""
    mock_resolve.side_effect = ResourceResolutionError("nope")

    with pytest.raises(ResourceResolutionError):
        get_dynamodb_health()

    mock_get_client.assert_not_called()
