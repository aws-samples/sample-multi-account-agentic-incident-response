"""Tests for get_service_health tool."""

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

from src.tools.service_health import get_service_health


@patch("src.tools.service_health.get_client")
def test_get_service_health_all_services(mock_get_client):
    """Test fetching health for all configured services."""
    mock_ecs = MagicMock()
    mock_get_client.return_value = mock_ecs

    mock_ecs.describe_services.return_value = {
        "services": [
            {
                "serviceName": "petsearch",
                "status": "ACTIVE",
                "desiredCount": 2,
                "runningCount": 2,
                "pendingCount": 0,
                "deployments": [{"id": "dep-1"}],
                "events": [
                    {
                        "createdAt": datetime(2025, 1, 15, 12, 0, 0, tzinfo=timezone.utc),
                        "message": "service has reached a steady state.",
                    }
                ],
            },
            {
                "serviceName": "payforadoption",
                "status": "ACTIVE",
                "desiredCount": 3,
                "runningCount": 3,
                "pendingCount": 0,
                "deployments": [{"id": "dep-2"}],
                "events": [],
            },
        ],
        "failures": [],
    }

    result = get_service_health()

    assert result["cluster"] == "PetsiteECS-cluster"
    assert "petsearch" in result["services"]
    assert result["services"]["petsearch"]["running_count"] == 2
    assert result["services"]["petsearch"]["desired_count"] == 2
    assert result["services"]["petsearch"]["status"] == "ACTIVE"
    assert len(result["services"]["petsearch"]["events"]) == 1
    assert result["services"]["payforadoption"]["running_count"] == 3


@patch("src.tools.service_health.get_client")
def test_get_service_health_single_service(mock_get_client):
    """Test fetching health for a specific service."""
    mock_ecs = MagicMock()
    mock_get_client.return_value = mock_ecs

    mock_ecs.describe_services.return_value = {
        "services": [
            {
                "serviceName": "petsearch",
                "status": "ACTIVE",
                "desiredCount": 2,
                "runningCount": 1,
                "pendingCount": 1,
                "deployments": [{"id": "dep-1"}, {"id": "dep-2"}],
                "events": [],
            }
        ],
        "failures": [],
    }

    result = get_service_health("petsearch")

    mock_ecs.describe_services.assert_called_once_with(
        cluster="PetsiteECS-cluster",
        services=["petsearch"],
    )
    assert result["services"]["petsearch"]["pending_count"] == 1
    assert result["services"]["petsearch"]["deployments"] == 2


@patch("src.tools.service_health.get_client")
def test_get_service_health_with_failures(mock_get_client):
    """Test handling of ECS service failures."""
    mock_ecs = MagicMock()
    mock_get_client.return_value = mock_ecs

    mock_ecs.describe_services.return_value = {
        "services": [],
        "failures": [
            {"arn": "arn:aws:ecs:us-east-1:123:service/bad", "reason": "MISSING"}
        ],
    }

    result = get_service_health("nonexistent")

    assert "_failures" in result["services"]
    assert result["services"]["_failures"][0]["reason"] == "MISSING"
