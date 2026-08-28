"""Tests for get_canary_results tool."""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

from src.tools.canary_results import get_canary_results


@patch("src.tools.canary_results.get_client")
def test_get_canary_results_success(mock_get_client):
    """Test canary results returns run details."""
    mock_synth = MagicMock()
    mock_get_client.return_value = mock_synth

    started = datetime(2025, 1, 15, 11, 55, 0, tzinfo=timezone.utc)
    completed = datetime(2025, 1, 15, 11, 55, 10, tzinfo=timezone.utc)

    mock_synth.get_canary.return_value = {
        "Canary": {
            "Status": {"State": "RUNNING", "StateReason": ""},
            "Schedule": {"Expression": "rate(5 minutes)"},
            "Timeline": {
                "LastStarted": started,
                "LastStopped": None,
            },
        }
    }

    mock_synth.get_canary_runs.return_value = {
        "CanaryRuns": [
            {
                "Status": {"State": "PASSED", "StateReason": ""},
                "Timeline": {"Started": started, "Completed": completed},
            },
            {
                "Status": {"State": "FAILED", "StateReason": "Timeout"},
                "Timeline": {"Started": started, "Completed": completed},
            },
        ]
    }

    result = get_canary_results("petadoptions-canary")

    canary = result["canaries"]["petadoptions-canary"]
    assert canary["state"] == "RUNNING"
    assert canary["schedule_expression"] == "rate(5 minutes)"
    assert len(canary["recent_runs"]) == 2
    assert canary["recent_runs"][0]["state"] == "PASSED"
    assert canary["recent_runs"][0]["duration_seconds"] == 10.0
    assert canary["recent_runs"][1]["state"] == "FAILED"


@patch("src.tools.canary_results.get_client")
def test_get_canary_results_not_found(mock_get_client):
    """Test canary results handles not-found canary."""
    mock_synth = MagicMock()
    mock_get_client.return_value = mock_synth

    mock_synth.get_canary.side_effect = Exception("ResourceNotFoundException")

    result = get_canary_results("nonexistent-canary")

    assert "error" in result["canaries"]["nonexistent-canary"]
