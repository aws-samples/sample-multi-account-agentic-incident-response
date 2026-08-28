"""Tests for get_queue_stats tool."""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

from src.config import BE_ACCOUNT_ID, REGION
from src.resource_resolver import ResourceResolutionError
from src.tools.queue_stats import get_queue_stats

# Same shape as the CloudFormation-generated queue name, no real value.
RESOLVED_QUEUE_NAME = "DevCoreStack-QueueResourcessqspetadoption-Sy1Th3T1cAbc"
RESOLVED_QUEUE_URL = (
    f"https://sqs.{REGION}.amazonaws.com/{BE_ACCOUNT_ID}/{RESOLVED_QUEUE_NAME}"
)


def _stub_clients(mock_get_client, *, age_datapoints=None, attributes=None):
    """Wire mock sqs + cloudwatch clients with usable responses."""
    mock_sqs = MagicMock()
    mock_cw = MagicMock()
    mock_get_client.side_effect = [mock_sqs, mock_cw]
    mock_sqs.get_queue_attributes.return_value = {
        "Attributes": attributes
        or {
            "ApproximateNumberOfMessages": "1",
            "ApproximateNumberOfMessagesNotVisible": "0",
            "ApproximateNumberOfMessagesDelayed": "0",
        }
    }
    mock_cw.get_metric_statistics.return_value = {
        "Datapoints": age_datapoints or []
    }
    return mock_sqs, mock_cw


def _dimension_value(mock_cw):
    """Return the QueueName dimension the CloudWatch call used."""
    dimensions = mock_cw.get_metric_statistics.call_args.kwargs["Dimensions"]
    return next(d["Value"] for d in dimensions if d["Name"] == "QueueName")


@patch("src.tools.queue_stats.resolve_status_update_queue")
@patch("src.tools.queue_stats.get_client")
def test_get_queue_stats_returns_metrics(mock_get_client, mock_resolve):
    """Test SQS queue stats returns all expected metrics."""
    mock_resolve.return_value = (RESOLVED_QUEUE_URL, RESOLVED_QUEUE_NAME)
    ts = datetime(2025, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
    _stub_clients(
        mock_get_client,
        attributes={
            "ApproximateNumberOfMessages": "42",
            "ApproximateNumberOfMessagesNotVisible": "5",
            "ApproximateNumberOfMessagesDelayed": "0",
        },
        age_datapoints=[{"Timestamp": ts, "Maximum": 120.0}],
    )

    result = get_queue_stats()

    assert result["queue_name"] == RESOLVED_QUEUE_NAME
    assert result["messages_visible"] == 42
    assert result["messages_in_flight"] == 5
    assert result["messages_delayed"] == 0
    assert result["age_of_oldest_message_seconds"] == 120.0


@patch("src.tools.queue_stats.resolve_status_update_queue")
@patch("src.tools.queue_stats.get_client")
def test_get_queue_stats_no_age_datapoints(mock_get_client, mock_resolve):
    """Test queue stats when age metric has no datapoints."""
    mock_resolve.return_value = (RESOLVED_QUEUE_URL, RESOLVED_QUEUE_NAME)
    _stub_clients(
        mock_get_client,
        attributes={
            "ApproximateNumberOfMessages": "0",
            "ApproximateNumberOfMessagesNotVisible": "0",
            "ApproximateNumberOfMessagesDelayed": "0",
        },
    )

    result = get_queue_stats()

    assert result["messages_visible"] == 0
    assert result["age_of_oldest_message_seconds"] == 0


@patch("src.tools.queue_stats.resolve_status_update_queue")
@patch("src.tools.queue_stats.get_client")
def test_get_queue_stats_default_uses_resolved_queue(mock_get_client, mock_resolve):
    """Omitting queue_name uses the queue the resolver reports, URL and dimension."""
    mock_resolve.return_value = (RESOLVED_QUEUE_URL, RESOLVED_QUEUE_NAME)
    mock_sqs, mock_cw = _stub_clients(mock_get_client)

    result = get_queue_stats()

    mock_resolve.assert_called_once_with(None)
    assert mock_sqs.get_queue_attributes.call_args.kwargs["QueueUrl"] == (
        RESOLVED_QUEUE_URL
    )
    assert _dimension_value(mock_cw) == RESOLVED_QUEUE_NAME
    assert result["queue_name"] == RESOLVED_QUEUE_NAME


@patch("src.tools.queue_stats.get_client")
def test_get_queue_stats_accepts_queue_name(mock_get_client):
    """A caller-supplied bare name is turned into a queue URL and used as-is."""
    mock_sqs, mock_cw = _stub_clients(mock_get_client)

    result = get_queue_stats(RESOLVED_QUEUE_NAME)

    queue_url = mock_sqs.get_queue_attributes.call_args.kwargs["QueueUrl"]
    assert queue_url.endswith(f"/{RESOLVED_QUEUE_NAME}")
    assert _dimension_value(mock_cw) == RESOLVED_QUEUE_NAME
    assert result["queue_name"] == RESOLVED_QUEUE_NAME


@patch("src.tools.queue_stats.get_client")
def test_get_queue_stats_accepts_queue_url(mock_get_client):
    """A full /petstore/queueurl value is used as-is; the name is its last segment."""
    mock_sqs, mock_cw = _stub_clients(mock_get_client)

    result = get_queue_stats(RESOLVED_QUEUE_URL)

    assert mock_sqs.get_queue_attributes.call_args.kwargs["QueueUrl"] == (
        RESOLVED_QUEUE_URL
    )
    assert _dimension_value(mock_cw) == RESOLVED_QUEUE_NAME
    assert result["queue_name"] == RESOLVED_QUEUE_NAME


@patch("src.tools.queue_stats.resolve_status_update_queue")
@patch("src.tools.queue_stats.get_client")
def test_get_queue_stats_propagates_resolution_failure(mock_get_client, mock_resolve):
    """An unresolvable queue is an error, never a fallback to a stale literal."""
    mock_resolve.side_effect = ResourceResolutionError("nope")

    with pytest.raises(ResourceResolutionError):
        get_queue_stats()

    mock_get_client.assert_not_called()
