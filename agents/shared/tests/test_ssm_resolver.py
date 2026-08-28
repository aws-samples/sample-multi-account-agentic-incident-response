"""Unit tests for ssm_resolver module."""

from unittest.mock import MagicMock, patch

import pytest

from agents.shared.ssm_resolver import SSMResolver


@pytest.fixture
def mock_ssm():
    """Return a mocked SSM client."""
    client = MagicMock()
    client.exceptions = MagicMock()
    client.exceptions.ParameterNotFound = type("ParameterNotFound", (Exception,), {})
    return client


class TestSSMResolver:
    def test_get_returns_parameter_value(self, mock_ssm):
        mock_ssm.get_parameter.return_value = {
            "Parameter": {"Value": "my-cluster-name"}
        }
        resolver = SSMResolver(ssm_client=mock_ssm, prefix="/aiops-poc/workload")

        result = resolver.get("ecs/cluster")

        assert result == "my-cluster-name"
        mock_ssm.get_parameter.assert_called_once_with(
            Name="/aiops-poc/workload/ecs/cluster"
        )

    def test_get_caches_value(self, mock_ssm):
        mock_ssm.get_parameter.return_value = {
            "Parameter": {"Value": "cached-value"}
        }
        resolver = SSMResolver(ssm_client=mock_ssm, prefix="/aiops-poc/workload")

        resolver.get("key")
        resolver.get("key")

        # Should only call SSM once due to caching
        mock_ssm.get_parameter.assert_called_once()

    def test_get_raises_key_error_when_not_found(self, mock_ssm):
        mock_ssm.get_parameter.side_effect = mock_ssm.exceptions.ParameterNotFound(
            "not found"
        )
        resolver = SSMResolver(ssm_client=mock_ssm, prefix="/aiops-poc/workload")

        with pytest.raises(KeyError, match="SSM parameter not found"):
            resolver.get("nonexistent")

    def test_get_all_paginates(self, mock_ssm):
        paginator = MagicMock()
        paginator.paginate.return_value = [
            {
                "Parameters": [
                    {"Name": "/aiops-poc/workload/ecs/cluster", "Value": "cluster-1"},
                    {"Name": "/aiops-poc/workload/sqs/queue", "Value": "queue-url"},
                ]
            }
        ]
        mock_ssm.get_paginator.return_value = paginator
        resolver = SSMResolver(ssm_client=mock_ssm, prefix="/aiops-poc/workload")

        result = resolver.get_all()

        assert result == {"ecs/cluster": "cluster-1", "sqs/queue": "queue-url"}

    def test_refresh_clears_cache(self, mock_ssm):
        mock_ssm.get_parameter.return_value = {
            "Parameter": {"Value": "v1"}
        }
        resolver = SSMResolver(ssm_client=mock_ssm, prefix="/aiops-poc/workload")

        resolver.get("key")
        resolver.refresh()

        # After refresh, next get should call SSM again
        mock_ssm.get_parameter.return_value = {
            "Parameter": {"Value": "v2"}
        }
        result = resolver.get("key")
        assert result == "v2"
        assert mock_ssm.get_parameter.call_count == 2
