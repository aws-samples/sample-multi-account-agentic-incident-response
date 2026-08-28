"""Entry point for the backend-kb-agent — protocol switch (python -m kb_agent).

SERVE_PROTOCOL selects the serving mode (AgentCore Runtime contract):
- MCP (default, PRIMARY): FastMCP streamable HTTP on 0.0.0.0:8000 at /mcp,
  single `investigate` tool (kb_agent/mcp_server.py).
- A2A (ALTERNATE variant, kept for demonstration): ASGI A2A app on
  0.0.0.0:9000 with agent card + /ping + POST / (kb_agent/app.py — still
  directly runnable as `python -m kb_agent.app`). The MCP mode is primary
  because the fallback interconnect link switched from remoteagentsigv4
  (A2A) to mcpserversigv4 (MCP) — the MCP registration gate has a known
  unblock process, the A2A gate does not.
"""

import os

if __name__ == "__main__":
    protocol = os.environ.get("SERVE_PROTOCOL", "MCP").strip().upper()
    if protocol == "A2A":
        # ALTERNATE: A2A server on port 9000
        from .app import run

        run()
    else:
        # PRIMARY: MCP streamable HTTP on port 8000 at /mcp
        from .mcp_server import mcp

        mcp.run(transport="streamable-http")
