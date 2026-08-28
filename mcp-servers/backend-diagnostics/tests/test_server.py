"""Tests for the MCP server tool registration."""

from src.server import mcp


def test_server_has_seven_tools():
    """Verify the MCP server registers exactly seven tools."""
    # Access the internal tool registry
    tools = mcp._tool_manager._tools
    assert len(tools) == 7, f"Expected 7 tools, found {len(tools)}: {list(tools.keys())}"


def test_server_tool_names():
    """Verify all expected tool names are registered."""
    tools = mcp._tool_manager._tools
    expected_names = {
        "tool_get_service_health",
        "tool_get_lambda_stats",
        "tool_get_queue_stats",
        "tool_get_dynamodb_health",
        "tool_get_db_health",
        "tool_get_canary_results",
        "tool_get_recent_alarms",
    }
    assert set(tools.keys()) == expected_names


def test_server_tools_expose_caller_supplied_resource_names():
    """The four generated-name tools reach their override parameter over MCP."""
    tools = mcp._tool_manager._tools
    expected = {
        "tool_get_queue_stats": "queue_name",
        "tool_get_db_health": "cluster_id",
        "tool_get_lambda_stats": "function_name",
        "tool_get_dynamodb_health": "table_name",
    }
    for tool_name, param in expected.items():
        schema = tools[tool_name].parameters
        assert param in schema["properties"], f"{tool_name} does not expose {param}"
        # Optional: an existing caller that passes nothing still works.
        assert param not in schema.get("required", [])
