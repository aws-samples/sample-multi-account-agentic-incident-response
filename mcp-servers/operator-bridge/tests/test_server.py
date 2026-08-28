"""
Unit tests for the operator-bridge MCP server.

Uses unittest.mock to mock all boto3 interactions, keeping tests
fast and independent of AWS credentials.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from io import BytesIO
from unittest.mock import MagicMock, patch

import pytest
import pytest_asyncio

# Ensure test configuration is set before importing server
os.environ.setdefault("AWS_REGION", "us-east-1")
os.environ.setdefault("REPORTS_BUCKET", "test-reports-bucket")
os.environ.setdefault("SSM_PREFIX", "/aiops-poc")

from server import (  # noqa: E402
    _ask_agent,
    _get_incident_report,
    _get_investigation_status,
    _list_recent_incidents,
    _start_investigation,
    app,
    call_tool,
    list_tools,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def mock_env(monkeypatch):
    """Set environment variables for all tests."""
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("REPORTS_BUCKET", "test-reports-bucket")
    monkeypatch.setenv("SSM_PREFIX", "/aiops-poc")


# ---------------------------------------------------------------------------
# Tests: list_tools
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tools_returns_five_tools():
    """The server should expose exactly 5 tools."""
    tools = await list_tools()
    assert len(tools) == 5
    names = {t.name for t in tools}
    assert names == {
        "start_investigation",
        "ask_agent",
        "get_investigation_status",
        "get_incident_report",
        "list_recent_incidents",
    }


@pytest.mark.asyncio
async def test_tool_schemas_have_required_fields():
    """Each tool should have a valid input schema."""
    tools = await list_tools()
    for tool in tools:
        assert tool.inputSchema is not None
        assert tool.inputSchema["type"] == "object"
        assert "properties" in tool.inputSchema


# ---------------------------------------------------------------------------
# Tests: start_investigation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("server._lambda_client")
@patch("server._ssm_client")
async def test_start_investigation_success(mock_ssm, mock_lambda):
    """start_investigation should invoke the webhook bridge and return an incident_id."""
    mock_ssm_instance = MagicMock()
    mock_ssm_instance.get_parameter.return_value = {
        "Parameter": {"Value": "aiops-poc-webhook-bridge"}
    }
    mock_ssm.return_value = mock_ssm_instance

    mock_lambda_instance = MagicMock()
    mock_lambda_instance.invoke.return_value = {"StatusCode": 202}
    mock_lambda.return_value = mock_lambda_instance

    result = await _start_investigation("checkout latency p99 > 2s")

    assert len(result) == 1
    data = json.loads(result[0].text)
    assert data["status"] == "investigation_started"
    assert data["incident_id"].startswith("INC-")
    assert data["symptom"] == "checkout latency p99 > 2s"
    assert "timestamp" in data

    # Verify SSM was queried for the function name
    mock_ssm_instance.get_parameter.assert_called_once_with(
        Name="/aiops-poc/webhook-bridge-function"
    )

    # Verify Lambda was invoked asynchronously
    mock_lambda_instance.invoke.assert_called_once()
    call_kwargs = mock_lambda_instance.invoke.call_args[1]
    assert call_kwargs["InvocationType"] == "Event"


@pytest.mark.asyncio
@patch("server._ssm_client")
async def test_start_investigation_lambda_not_deployed(mock_ssm):
    """start_investigation should gracefully handle missing Lambda."""
    mock_ssm_instance = MagicMock()
    mock_ssm_instance.get_parameter.side_effect = Exception(
        "ParameterNotFound: /aiops-poc/webhook-bridge-function"
    )
    mock_ssm.return_value = mock_ssm_instance

    result = await _start_investigation("search unavailable")

    data = json.loads(result[0].text)
    assert data["status"] == "trigger_failed"
    assert "incident_id" in data
    assert "error" in data


# ---------------------------------------------------------------------------
# Tests: ask_agent
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("server._lambda_client")
@patch("server._ssm_client")
async def test_ask_agent_success(mock_ssm, mock_lambda):
    """ask_agent should resolve the endpoint and invoke the agent proxy."""
    mock_ssm_instance = MagicMock()
    mock_ssm_instance.get_parameter.return_value = {
        "Parameter": {"Value": "https://agent.example.com/devops"}
    }
    mock_ssm.return_value = mock_ssm_instance

    agent_response = {"answer": "The root cause is db-overload", "confidence": "high"}
    mock_lambda_instance = MagicMock()
    mock_payload = MagicMock()
    mock_payload.read.return_value = json.dumps(agent_response).encode()
    mock_lambda_instance.invoke.return_value = {"Payload": mock_payload}
    mock_lambda.return_value = mock_lambda_instance

    result = await _ask_agent("devops", "What is the root cause?")

    data = json.loads(result[0].text)
    assert data["answer"] == "The root cause is db-overload"
    assert data["confidence"] == "high"


@pytest.mark.asyncio
@patch("server._ssm_client")
async def test_ask_agent_endpoint_not_found(mock_ssm):
    """ask_agent should return an error if the agent endpoint is not in SSM."""
    mock_ssm_instance = MagicMock()
    mock_ssm_instance.get_parameter.side_effect = Exception("ParameterNotFound")
    mock_ssm.return_value = mock_ssm_instance

    result = await _ask_agent("kb", "What docs exist?")

    data = json.loads(result[0].text)
    assert data["status"] == "error"
    assert data["agent"] == "kb"
    assert "endpoint" in data["error"].lower()


# ---------------------------------------------------------------------------
# Tests: get_investigation_status
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("server._s3_client")
async def test_get_investigation_status_completed(mock_s3):
    """Should return 'completed' if a report exists in S3."""
    mock_s3_instance = MagicMock()
    mock_s3_instance.head_object.return_value = {"ContentLength": 1234}
    mock_s3_instance.exceptions = MagicMock()
    mock_s3.return_value = mock_s3_instance

    result = await _get_investigation_status("INC-ABC12345")

    data = json.loads(result[0].text)
    assert data["status"] == "completed"
    assert data["incident_id"] == "INC-ABC12345"


@pytest.mark.asyncio
@patch("server._ssm_client")
@patch("server._s3_client")
async def test_get_investigation_status_in_progress(mock_s3, mock_ssm):
    """Should check SSM for status if no report exists in S3."""
    # S3 head_object raises 404
    mock_s3_instance = MagicMock()
    error_response = {"Error": {"Code": "404", "Message": "Not Found"}}
    mock_s3_instance.head_object.side_effect = mock_s3_instance.exceptions.ClientError(
        error_response, "HeadObject"
    )
    # Make the ClientError checkable
    from botocore.exceptions import ClientError

    mock_s3_instance.head_object.side_effect = ClientError(error_response, "HeadObject")
    mock_s3_instance.exceptions.ClientError = ClientError
    mock_s3.return_value = mock_s3_instance

    # SSM returns in_progress
    mock_ssm_instance = MagicMock()
    mock_ssm_instance.get_parameter.return_value = {
        "Parameter": {"Value": "in_progress"}
    }
    mock_ssm.return_value = mock_ssm_instance

    result = await _get_investigation_status("INC-DEF67890")

    data = json.loads(result[0].text)
    assert data["status"] == "in_progress"
    assert data["incident_id"] == "INC-DEF67890"


@pytest.mark.asyncio
@patch("server._ssm_client")
@patch("server._s3_client")
async def test_get_investigation_status_unknown(mock_s3, mock_ssm):
    """Should return 'unknown' if neither S3 nor SSM has the incident."""
    from botocore.exceptions import ClientError

    mock_s3_instance = MagicMock()
    error_response = {"Error": {"Code": "404", "Message": "Not Found"}}
    mock_s3_instance.head_object.side_effect = ClientError(error_response, "HeadObject")
    mock_s3_instance.exceptions.ClientError = ClientError
    mock_s3.return_value = mock_s3_instance

    mock_ssm_instance = MagicMock()
    mock_ssm_instance.get_parameter.side_effect = Exception("ParameterNotFound")
    mock_ssm.return_value = mock_ssm_instance

    result = await _get_investigation_status("INC-NOTEXIST")

    data = json.loads(result[0].text)
    assert data["status"] == "unknown"


# ---------------------------------------------------------------------------
# Tests: get_incident_report
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("server._s3_client")
async def test_get_incident_report_success(mock_s3):
    """Should return the full report JSON from S3."""
    report = {
        "incident_id": "INC-TEST001",
        "status": "resolved",
        "root_cause": {"fault_id": "db-overload", "confidence": "high"},
        "business_impact": "Checkout latency elevated for 8 minutes",
        "evidence": [
            {"metric": "payforadoption_p99", "value": 4200, "threshold": 2000}
        ],
    }

    mock_s3_instance = MagicMock()
    body_stream = MagicMock()
    body_stream.read.return_value = json.dumps(report).encode()
    mock_s3_instance.get_object.return_value = {"Body": body_stream}
    mock_s3.return_value = mock_s3_instance

    result = await _get_incident_report("INC-TEST001")

    data = json.loads(result[0].text)
    assert data["incident_id"] == "INC-TEST001"
    assert data["root_cause"]["fault_id"] == "db-overload"

    mock_s3_instance.get_object.assert_called_once_with(
        Bucket="test-reports-bucket", Key="reports/INC-TEST001.json"
    )


@pytest.mark.asyncio
@patch("server._s3_client")
async def test_get_incident_report_not_found(mock_s3):
    """Should return an error if the report doesn't exist."""
    mock_s3_instance = MagicMock()
    mock_s3_instance.get_object.side_effect = Exception("NoSuchKey: reports/INC-NOPE.json")
    mock_s3.return_value = mock_s3_instance

    result = await _get_incident_report("INC-NOPE")

    data = json.loads(result[0].text)
    assert data["status"] == "error"
    assert "NoSuchKey" in data["error"]


# ---------------------------------------------------------------------------
# Tests: list_recent_incidents
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("server._s3_client")
async def test_list_recent_incidents_with_reports(mock_s3):
    """Should list incidents from S3 sorted by last_modified descending."""
    mock_s3_instance = MagicMock()
    mock_s3_instance.list_objects_v2.return_value = {
        "Contents": [
            {
                "Key": "reports/INC-001.json",
                "LastModified": datetime(2024, 6, 1, 10, 0, 0, tzinfo=timezone.utc),
                "Size": 512,
            },
            {
                "Key": "reports/INC-002.json",
                "LastModified": datetime(2024, 6, 2, 14, 30, 0, tzinfo=timezone.utc),
                "Size": 1024,
            },
        ]
    }
    mock_s3.return_value = mock_s3_instance

    result = await _list_recent_incidents()

    data = json.loads(result[0].text)
    assert data["count"] == 2
    # Most recent first
    assert data["incidents"][0]["incident_id"] == "INC-002"
    assert data["incidents"][1]["incident_id"] == "INC-001"


@pytest.mark.asyncio
@patch("server._s3_client")
async def test_list_recent_incidents_empty(mock_s3):
    """Should return empty list if no reports exist."""
    mock_s3_instance = MagicMock()
    mock_s3_instance.list_objects_v2.return_value = {}
    mock_s3.return_value = mock_s3_instance

    result = await _list_recent_incidents()

    data = json.loads(result[0].text)
    assert data["count"] == 0
    assert data["incidents"] == []


@pytest.mark.asyncio
@patch("server._s3_client")
async def test_list_recent_incidents_error(mock_s3):
    """Should handle S3 errors gracefully."""
    mock_s3_instance = MagicMock()
    mock_s3_instance.list_objects_v2.side_effect = Exception("AccessDenied")
    mock_s3.return_value = mock_s3_instance

    result = await _list_recent_incidents()

    data = json.loads(result[0].text)
    assert data["status"] == "error"
    assert "AccessDenied" in data["error"]


# ---------------------------------------------------------------------------
# Tests: call_tool dispatch
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("server._ssm_client")
async def test_call_tool_unknown_tool(mock_ssm):
    """Should handle unknown tool names gracefully."""
    result = await call_tool("nonexistent_tool", {})
    assert "Unknown tool" in result[0].text
