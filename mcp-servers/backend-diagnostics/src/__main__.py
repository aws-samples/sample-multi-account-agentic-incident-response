"""Entry point for the diagnostics MCP server — streamable HTTP on :8000/mcp."""

from .server import mcp

if __name__ == "__main__":
    # Host/port/path/statelessness are configured on the FastMCP instance in
    # server.py — FastMCP.run() only accepts the transport.
    mcp.run(transport="streamable-http")
