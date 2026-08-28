"""Entry point for the backend-devops-agent — protocol switch.

SERVE_PROTOCOL selects the serving mode (AgentCore Runtime contract):
- MCP (default, PRIMARY): FastMCP streamable HTTP on 0.0.0.0:8000 at /mcp,
  single `investigate` tool (src/mcp_server.py).
- A2A (ALTERNATE variant, kept for demonstration): Starlette A2A server on
  0.0.0.0:9000 with agent card + /ping + POST / (src/server.py). The MCP
  mode is primary because the fallback interconnect link switched from
  remoteagentsigv4 (A2A) to mcpserversigv4 (MCP) — the MCP registration
  gate has a known unblock process, the A2A gate does not.
"""

import logging
import os

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)

if __name__ == "__main__":
    protocol = os.environ.get("SERVE_PROTOCOL", "MCP").strip().upper()
    if protocol == "A2A":
        # ALTERNATE: A2A server on port 9000
        from .server import run_server

        run_server()
    else:
        # PRIMARY: MCP streamable HTTP on port 8000 at /mcp
        from .mcp_server import mcp

        mcp.run(transport="streamable-http")
