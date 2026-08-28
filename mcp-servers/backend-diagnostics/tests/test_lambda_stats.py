"""Tests for get_lambda_stats tool."""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

from src.resource_resolver import ResourceResolutionError
from src.tools.lambda_stats import get_lambda_stats

# Same shape as a CloudFormation-generated function name, no real value.
RESOLVED_FUNCTION = "DevCoreStack-StatusUpdater-Sy1Th3T1cAbc"


def _stub_cloudwatch(mock_get_client, datapoints=None):
    """Wire a mock cloudwatch client only — the default path lists nothing."""
    mock_cw = MagicMock()
    mock_get_client.return_value = mock_cw
    mock_cw.get_metric_statistics.return_value = {"Datapoints": datapoints or []}
    return mock_cw


def _stub_listing_clients(mock_get_client, function_names):
    """Wire mock lambda + cloudwatch clients listing *function_names*."""
    mock_lambda = MagicMock()
    mock_cw = MagicMock()
    mock_get_client.side_effect = [mock_lambda, mock_cw]

    mock_paginator = MagicMock()
    mock_lambda.get_paginator.return_value = mock_paginator
    mock_paginator.paginate.return_value = [
        {"Functions": [{"FunctionName": name} for name in function_names]}
    ]
    mock_cw.get_metric_statistics.return_value = {"Datapoints": []}
    return mock_lambda, mock_cw


def _dimension_values(mock_cw):
    """Return every FunctionName dimension the CloudWatch calls used."""
    values = set()
    for c in mock_cw.get_metric_statistics.call_args_list:
        for dim in c.kwargs["Dimensions"]:
            if dim["Name"] == "FunctionName":
                values.add(dim["Value"])
    return values


@patch("src.tools.lambda_stats.resolve_status_updater_function_name")
@patch("src.tools.lambda_stats.get_client")
def test_get_lambda_stats_returns_metrics(mock_get_client, mock_resolve):
    """The resolved status-updater gets one metric series per statistic."""
    mock_resolve.return_value = RESOLVED_FUNCTION
    ts = datetime(2025, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
    mock_cw = _stub_cloudwatch(
        mock_get_client, [{"Timestamp": ts, "Sum": 100, "Average": 250.5}]
    )

    result = get_lambda_stats(minutes=15)

    assert result["period_minutes"] == 15
    assert list(result["functions"]) == [RESOLVED_FUNCTION]
    assert result["functions"][RESOLVED_FUNCTION]["invocations"] == 100
    assert result["functions"][RESOLVED_FUNCTION]["duration"] == 250.5
    # Four metric queries for the one function.
    assert mock_cw.get_metric_statistics.call_count == 4
    assert _dimension_values(mock_cw) == {RESOLVED_FUNCTION}


@patch("src.tools.lambda_stats.resolve_status_updater_function_name")
@patch("src.tools.lambda_stats.get_client")
def test_get_lambda_stats_empty_datapoints(mock_get_client, mock_resolve):
    """Test Lambda stats handles empty datapoints gracefully."""
    mock_resolve.return_value = RESOLVED_FUNCTION
    _stub_cloudwatch(mock_get_client)

    result = get_lambda_stats(minutes=5)

    fn = result["functions"][RESOLVED_FUNCTION]
    assert fn["invocations"] == 0
    assert fn["errors"] == 0
    assert fn["duration"] == 0
    assert fn["throttles"] == 0


@patch("src.tools.lambda_stats.resolve_status_updater_function_name")
@patch("src.tools.lambda_stats.get_client")
def test_get_lambda_stats_propagates_resolution_failure(mock_get_client, mock_resolve):
    """An unresolvable status-updater is an error, not an empty result."""
    mock_resolve.side_effect = ResourceResolutionError("nope")

    with pytest.raises(ResourceResolutionError):
        get_lambda_stats()

    mock_get_client.assert_not_called()


@patch("src.tools.lambda_stats.resolve_status_updater_function_name")
@patch("src.tools.lambda_stats.get_client")
def test_get_lambda_stats_default_does_not_list_functions(
    mock_get_client, mock_resolve
):
    """The default path names the function outright instead of scanning them all."""
    mock_resolve.return_value = RESOLVED_FUNCTION
    mock_cw = _stub_cloudwatch(mock_get_client)

    get_lambda_stats()

    mock_get_client.assert_called_once_with("cloudwatch")
    mock_cw.get_paginator.assert_not_called()


@patch("src.tools.lambda_stats.resolve_status_updater_function_name")
@patch("src.tools.lambda_stats.get_client")
def test_get_lambda_stats_accepts_function_name(mock_get_client, mock_resolve):
    """A caller-supplied filter wins outright — the resolver is never consulted."""
    _, mock_cw = _stub_listing_clients(
        mock_get_client, [RESOLVED_FUNCTION, "unrelated-function"]
    )

    result = get_lambda_stats(minutes=15, function_name="DevCoreStack-StatusUpdater")

    mock_resolve.assert_not_called()
    assert list(result["functions"]) == [RESOLVED_FUNCTION]
    assert _dimension_values(mock_cw) == {RESOLVED_FUNCTION}


@patch("src.tools.lambda_stats.resolve_status_updater_function_name")
@patch("src.tools.lambda_stats.get_client")
def test_get_lambda_stats_function_name_matches_case_insensitively(
    mock_get_client, mock_resolve
):
    """The caller's substring is matched case-insensitively."""
    _stub_listing_clients(mock_get_client, [RESOLVED_FUNCTION])

    result = get_lambda_stats(function_name="devcorestack-statusupdater")

    assert list(result["functions"]) == [RESOLVED_FUNCTION]


@patch("src.tools.lambda_stats.resolve_status_updater_function_name")
@patch("src.tools.lambda_stats.get_client")
def test_get_lambda_stats_no_matching_functions(mock_get_client, mock_resolve):
    """A caller filter matching nothing returns an empty function map."""
    _stub_listing_clients(mock_get_client, ["other-function"])

    result = get_lambda_stats(function_name="nothing-matches-this")

    assert result["functions"] == {}
