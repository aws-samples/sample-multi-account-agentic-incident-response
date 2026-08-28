FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY pyproject.toml .
RUN pip install --no-cache-dir .

# Copy application source
COPY src/ src/

EXPOSE 8000

# Run the MCP server on port 8000 with streamable HTTP transport
CMD ["python", "-m", "src"]
