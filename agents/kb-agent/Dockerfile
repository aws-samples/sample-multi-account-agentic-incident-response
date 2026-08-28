FROM python:3.11-slim

WORKDIR /app

# Build context: agents/ directory (docker build -f kb-agent/Dockerfile .)
# Install shared dependencies first for layer caching
COPY shared/pyproject.toml /app/agents/shared/pyproject.toml
COPY shared/ /app/agents/shared/

# Copy agent code BEFORE the editable install: setuptools discovers packages
# at install time, so installing from a directory that only holds
# pyproject.toml produces an editable install that maps no modules
# (ModuleNotFoundError: kb_agent at runtime).
COPY kb-agent/ /app/agents/kb-agent/
RUN pip install --no-cache-dir \
    -e /app/agents/shared \
    -e /app/agents/kb-agent

# Copy skills (not used by KB agent but available for reference)
COPY skills/ /app/agents/skills/

ENV PYTHONPATH=/app
ENV A2A_PORT=9000
ENV INVESTIGATION_TIMEOUT=600

# Dual-protocol serving (SERVE_PROTOCOL env var, default MCP):
#   MCP (PRIMARY):   streamable HTTP on 8000 at /mcp (AgentCore MCP contract)
#   A2A (ALTERNATE): ASGI app on 9000 (AgentCore A2A contract)
EXPOSE 8000
EXPOSE 9000

# No HEALTHCHECK: the old /health probe only exists in A2A mode (the
# AgentCore MCP contract has no health endpoint on 8000), and AgentCore
# Runtime does its own health management anyway.

# Entry point reads SERVE_PROTOCOL and dispatches (kb_agent/__main__.py).
# The A2A app remains directly runnable via `python -m kb_agent.app`.
CMD ["python", "-m", "kb_agent"]
