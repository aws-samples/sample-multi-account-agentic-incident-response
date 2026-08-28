# Build context: agents/ directory (docker build -f backend-agent/Dockerfile .)
FROM python:3.11-slim

WORKDIR /app

# Install shared package first
COPY shared/pyproject.toml /app/agents/shared/pyproject.toml
COPY shared/ /app/agents/shared/
COPY __init__.py /app/agents/__init__.py
RUN pip install --no-cache-dir -e /app/agents/shared

# Install backend-agent dependencies
COPY backend-agent/pyproject.toml /app/pyproject.toml
RUN pip install --no-cache-dir .

# Copy skills catalog
COPY skills/ /app/agents/skills/

# Copy application source
COPY backend-agent/src/ /app/src/

# Set environment for skill loading and module resolution
ENV SKILLS_DIR=/app/agents/skills
ENV PYTHONPATH=/app

# Dual-protocol serving (SERVE_PROTOCOL env var, default MCP):
#   MCP (PRIMARY):   streamable HTTP on 8000 at /mcp (AgentCore MCP contract)
#   A2A (ALTERNATE): Starlette server on 9000 (AgentCore A2A contract)
EXPOSE 8000
EXPOSE 9000

# Entry point reads SERVE_PROTOCOL and dispatches (src/__main__.py)
CMD ["python", "-m", "src"]
