"""Tests for get_recent_alarms tool."""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

from src.tools.recent_alarms import get_recent_alarms


@patch("src.tools.recent_alarms.get_client")
def test_get_recent_alarms_returns_alarm_data(mock_get_client):
    """Test recent alarms returns state and history."""
    mock_cw = MagicMock()
    mock_get_client.return_value = mock_cw

    ts = datetime(2025, 1, 15, 12, 0, 0, tzinfo=timezone.utc)

    # Mock paginator for describe_alarms
    mock_paginator = MagicMock()
    mock_cw.get_paginator.return_value = mock_paginator
    mock_paginator.paginate.return_value = [
        {
            "MetricAlarms": [
                {
                    "AlarmName": "aiops-poc-checkout-latency",
                    "StateValue": "ALARM",
                    "StateReason": "Threshold crossed: p99 > 2s",
                    "StateUpdatedTimestamp": ts,
                }
            ],
            "CompositeAlarms": [],
        }
    ]

    mock_cw.describe_alarm_history.return_value = {
        "AlarmHistoryItems": [
            {
                "Timestamp": ts,
                "HistorySummary": "Alarm updated from OK to ALARM",
            }
        ]
    }

    result = get_recent_alarms(minutes=30)

    assert result["lookback_minutes"] == 30
    assert result["alarm_prefix"] == "aiops-poc"
    assert len(result["alarms"]) == 1

    alarm = result["alarms"][0]
    assert alarm["alarm_name"] == "aiops-poc-checkout-latency"
    assert alarm["current_state"] == "ALARM"
    assert len(alarm["recent_state_changes"]) == 1
    assert "OK to ALARM" in alarm["recent_state_changes"][0]["summary"]


@patch("src.tools.recent_alarms.get_client")
def test_get_recent_alarms_empty(mock_get_client):
    """Test recent alarms returns empty when no alarms exist."""
    mock_cw = MagicMock()
    mock_get_client.return_value = mock_cw

    mock_paginator = MagicMock()
    mock_cw.get_paginator.return_value = mock_paginator
    mock_paginator.paginate.return_value = [
        {"MetricAlarms": [], "CompositeAlarms": []}
    ]

    result = get_recent_alarms()

    assert result["alarms"] == []


@patch("src.tools.recent_alarms.get_client")
def test_get_recent_alarms_history_error_handled(mock_get_client):
    """Test recent alarms handles history API errors gracefully."""
    mock_cw = MagicMock()
    mock_get_client.return_value = mock_cw

    ts = datetime(2025, 1, 15, 12, 0, 0, tzinfo=timezone.utc)

    mock_paginator = MagicMock()
    mock_cw.get_paginator.return_value = mock_paginator
    mock_paginator.paginate.return_value = [
        {
            "MetricAlarms": [
                {
                    "AlarmName": "aiops-poc-search-slo",
                    "StateValue": "OK",
                    "StateReason": "All good",
                    "StateUpdatedTimestamp": ts,
                }
            ],
            "CompositeAlarms": [],
        }
    ]

    mock_cw.describe_alarm_history.side_effect = Exception("AccessDenied")

    result = get_recent_alarms()

    # Should still return alarm info even if history fails
    assert len(result["alarms"]) == 1
    assert result["alarms"][0]["recent_state_changes"] == []
