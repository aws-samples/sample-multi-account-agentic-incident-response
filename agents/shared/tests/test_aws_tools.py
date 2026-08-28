"""Unit tests for aws_tools module (mocked boto3)."""

import re
from pathlib import Path
from unittest.mock import MagicMock, patch
from datetime import datetime, timezone

import pytest

AWS_TOOLS_SOURCE = Path(__file__).resolve().parent.parent / "aws_tools.py"


class TestBackendAccountIsSupplied:
    """The account comes from the environment, never from a literal.

    These wrappers are an unused alternate path since the knowledge-only
    descope, so nothing populates BE_ACCOUNT_ID for them. A caller that reaches
    the assume-role path without supplying it fails cleanly instead of reaching
    a stale hardcoded account.

    Validates: Requirements 5.1, 5.2, 5.3
    """

    def test_missing_account_fails_naming_the_variable(self, monkeypatch):
        monkeypatch.delenv("BE_ACCOUNT_ID", raising=False)

        from agents.shared.aws_tools import _assume_be_role_credentials

        with pytest.raises(RuntimeError) as excinfo:
            _assume_be_role_credentials()
        message = str(excinfo.value)
        assert "BE_ACCOUNT_ID" in message
        assert "config/accounts.json" in message

    def test_blank_account_is_treated_as_missing(self, monkeypatch):
        monkeypatch.setenv("BE_ACCOUNT_ID", "  ")

        from agents.shared.aws_tools import _be_account_id

        with pytest.raises(RuntimeError) as excinfo:
            _be_account_id()
        assert "BE_ACCOUNT_ID" in str(excinfo.value)

    def test_supplied_account_is_the_value_used(self, monkeypatch):
        monkeypatch.setenv("BE_ACCOUNT_ID", "333333333333")

        from agents.shared.aws_tools import _be_account_id

        assert _be_account_id() == "333333333333"

    def test_module_contains_no_twelve_digit_literal(self):
        source = AWS_TOOLS_SOURCE.read_text()
        assert re.search(r"\d{12}", source) is None, (
            "aws_tools.py must contain no account-ID literal — the account is a "
            "Replicator input supplied through BE_ACCOUNT_ID"
        )


class TestAssumeRole:
    @patch("agents.shared.aws_tools.boto3.client")
    def test_assume_role_calls_sts(self, mock_boto_client, monkeypatch):
        monkeypatch.setenv("BE_ACCOUNT_ID", "111111111111")
        mock_sts = MagicMock()
        mock_sts.assume_role.return_value = {
            "Credentials": {
                "AccessKeyId": "AKIA_TEST",
                "SecretAccessKey": "secret",
                "SessionToken": "token",
            }
        }
        mock_boto_client.return_value = mock_sts

        from agents.shared.aws_tools import _assume_be_role_credentials

        creds = _assume_be_role_credentials()

        assert creds["aws_access_key_id"] == "AKIA_TEST"
        assert creds["aws_secret_access_key"] == "secret"
        assert creds["aws_session_token"] == "token"
        mock_sts.assume_role.assert_called_once()
        call_args = mock_sts.assume_role.call_args[1]
        assert "111111111111" in call_args["RoleArn"]
        assert "aiops-backend-domain-read" in call_args["RoleArn"]


class TestGetRecentAlarms:
    @patch("agents.shared.aws_tools._be_client")
    def test_returns_alarm_list(self, mock_be_client):
        mock_cw = MagicMock()
        mock_cw.describe_alarms.return_value = {
            "MetricAlarms": [
                {
                    "AlarmName": "checkout-latency-high",
                    "StateValue": "ALARM",
                    "StateReason": "Threshold crossed",
                    "StateUpdatedTimestamp": datetime(2024, 1, 15, 10, 0, tzinfo=timezone.utc),
                }
            ]
        }
        mock_be_client.return_value = mock_cw

        from agents.shared.aws_tools import get_recent_alarms

        result = get_recent_alarms()

        assert len(result) == 1
        assert result[0]["name"] == "checkout-latency-high"
        assert result[0]["state"] == "ALARM"


class TestGetServiceHealth:
    @patch("agents.shared.aws_tools._be_client")
    def test_returns_service_health(self, mock_be_client):
        mock_ecs = MagicMock()
        mock_ecs.describe_services.return_value = {
            "services": [
                {
                    "serviceName": "payforadoption",
                    "status": "ACTIVE",
                    "desiredCount": 2,
                    "runningCount": 2,
                    "pendingCount": 0,
                    "deployments": [{}],
                    "events": [{"message": "service reached steady state"}],
                }
            ]
        }
        mock_be_client.return_value = mock_ecs

        from agents.shared.aws_tools import get_service_health

        result = get_service_health("main-cluster", "payforadoption")

        assert result["service"] == "payforadoption"
        assert result["running"] == 2
        assert result["desired"] == 2

    @patch("agents.shared.aws_tools._be_client")
    def test_returns_error_when_not_found(self, mock_be_client):
        mock_ecs = MagicMock()
        mock_ecs.describe_services.return_value = {"services": []}
        mock_be_client.return_value = mock_ecs

        from agents.shared.aws_tools import get_service_health

        result = get_service_health("cluster", "missing-service")
        assert "error" in result


class TestGetDynamoDBHealth:
    @patch("agents.shared.aws_tools._be_client")
    def test_returns_table_info(self, mock_be_client):
        mock_ddb = MagicMock()
        mock_ddb.describe_table.return_value = {
            "Table": {
                "TableName": "petadoptions",
                "TableStatus": "ACTIVE",
                "ItemCount": 150,
                "TableSizeBytes": 65536,
                "ProvisionedThroughput": {"ReadCapacityUnits": 5, "WriteCapacityUnits": 5},
            }
        }
        mock_be_client.return_value = mock_ddb

        from agents.shared.aws_tools import get_dynamodb_health

        result = get_dynamodb_health("petadoptions")

        assert result["table"] == "petadoptions"
        assert result["status"] == "ACTIVE"
        assert result["item_count"] == 150


class TestGetQueueStats:
    @patch("agents.shared.aws_tools._be_client")
    def test_returns_queue_attributes(self, mock_be_client):
        mock_sqs = MagicMock()
        mock_sqs.get_queue_attributes.return_value = {
            "Attributes": {
                "ApproximateNumberOfMessages": "42",
                "ApproximateNumberOfMessagesNotVisible": "3",
                "ApproximateNumberOfMessagesDelayed": "0",
                "ApproximateAgeOfOldestMessage": "120",
            }
        }
        mock_be_client.return_value = mock_sqs

        from agents.shared.aws_tools import get_queue_stats

        result = get_queue_stats("https://sqs.us-east-1.amazonaws.com/123/queue")

        assert result["messages_available"] == 42
        assert result["oldest_message_age_seconds"] == 120


class TestGetDBHealth:
    @patch("agents.shared.aws_tools._be_client")
    def test_returns_db_info(self, mock_be_client):
        mock_rds = MagicMock()
        mock_rds.describe_db_instances.return_value = {
            "DBInstances": [
                {
                    "DBInstanceIdentifier": "petadoptions-db",
                    "DBInstanceStatus": "available",
                    "Engine": "aurora-postgresql",
                    "EngineVersion": "15.4",
                    "DBInstanceClass": "db.r5.large",
                    "MultiAZ": True,
                    "AllocatedStorage": 100,
                }
            ]
        }
        mock_be_client.return_value = mock_rds

        from agents.shared.aws_tools import get_db_health

        result = get_db_health("petadoptions-db")

        assert result["identifier"] == "petadoptions-db"
        assert result["engine"] == "aurora-postgresql"
        assert result["multi_az"] is True


class TestGetLambdaStats:
    @patch("agents.shared.aws_tools._be_client")
    def test_returns_lambda_config(self, mock_be_client):
        mock_lam = MagicMock()
        mock_lam.get_function_configuration.return_value = {
            "FunctionName": "petadoptions-processor",
            "Runtime": "python3.11",
            "MemorySize": 256,
            "Timeout": 30,
            "State": "Active",
            "LastModified": "2024-01-15T10:00:00.000+0000",
        }
        mock_be_client.return_value = mock_lam

        from agents.shared.aws_tools import get_lambda_stats

        result = get_lambda_stats("petadoptions-processor")

        assert result["function"] == "petadoptions-processor"
        assert result["memory_mb"] == 256
        assert result["state"] == "Active"


class TestGetCanaryResults:
    @patch("agents.shared.aws_tools._be_client")
    def test_returns_canary_runs(self, mock_be_client):
        mock_syn = MagicMock()
        mock_syn.get_canary_runs.return_value = {
            "CanaryRuns": [
                {
                    "Status": {"State": "PASSED"},
                    "Timeline": {
                        "Started": datetime(2024, 1, 15, 10, 0, tzinfo=timezone.utc),
                        "DurationInMilliseconds": 3500,
                    },
                }
            ]
        }
        mock_be_client.return_value = mock_syn

        from agents.shared.aws_tools import get_canary_results

        result = get_canary_results("journey-canary")

        assert result["canary"] == "journey-canary"
        assert len(result["runs"]) == 1
        assert result["runs"][0]["status"] == "PASSED"
