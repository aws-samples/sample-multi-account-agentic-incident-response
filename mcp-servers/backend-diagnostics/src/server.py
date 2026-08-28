"""Backend Diagnostics MCP Server — seven deterministic tools over streamable HTTP.

Exposes read-only AWS diagnostic tools for the PetAdoptions backend on
port 8000, path /mcp. Uses the aiops-backend-domain-read role (STS assume-role)
to access BE account resources.
"""

from mcp.server.fastmcp import FastMCP

from .tools.service_health import get_service_health
from .tools.lambda_stats import get_lambda_stats
from .tools.queue_stats import get_queue_stats
from .tools.dynamodb_health import get_dynamodb_health
from .tools.db_health import get_db_health
from .tools.canary_results import get_canary_results
from .tools.recent_alarms import get_recent_alarms

mcp = FastMCP(
    "Backend Diagnostics",
    instructions=(
        "Deterministic diagnostic tools for the PetAdoptions backend workload. "
        "All tools return structured data from AWS APIs — no LLM involvement. "
        "Use these tools to inspect ECS services, Lambda functions, SQS queues, "
        "DynamoDB tables, Aurora/RDS clusters, Synthetics canaries, and CloudWatch alarms."
    ),
    # AgentCore Runtime MCP contract: bind 0.0.0.0:8000, path /mcp, stateless
    # streamable HTTP (the platform generates Mcp-Session-Id headers and load
    # balances across microVMs, so the server must not track sessions).
    host="0.0.0.0",  # nosec B104  # AgentCore Runtime ingress requires the container to listen on 0.0.0.0; the port is not internet-facing and callers are authenticated with SigV4 at the data plane
    port=8000,
    streamable_http_path="/mcp",
    stateless_http=True,
)


@mcp.tool()
def tool_get_service_health(service_name: str | None = None) -> dict:
    """Get ECS service health for PetAdoptions services.

    Returns running/desired task counts, deployment status, and recent events
    for the PetAdoptions ECS services (petsearch, payforadoption,
    petlistadoptions, petstatusupdater).

    Args:
        service_name: Optional specific service name. If omitted, returns all services.
    """
    return get_service_health(service_name)


@mcp.tool()
def tool_get_lambda_stats(minutes: int = 15, function_name: str | None = None) -> dict:
    """Get Lambda function metrics for the status-updater function.

    Returns invocations, errors, average duration, and throttles for Lambda
    functions whose name matches the filter.

    Args:
        minutes: Lookback window in minutes (default 15).
        function_name: Optional function name, or any substring of one, matched
            case-insensitively. Omit it to inspect the status-updater: the
            server resolves it at runtime as the function whose event source
            mapping consumes the queue named by the /petstore/queueurl SSM
            parameter in the backend account.
    """
    return get_lambda_stats(minutes, function_name)


@mcp.tool()
def tool_get_queue_stats(queue_name: str | None = None) -> dict:
    """Get SQS queue metrics for the pet status update queue.

    Returns messages visible, messages in-flight, messages delayed,
    and age of the oldest message (seconds) — the business lag indicator.

    Args:
        queue_name: Optional queue name or full queue URL, used as given. Omit
            it to use the status-update queue: the server reads its URL from the
            /petstore/queueurl SSM parameter in the backend account.
    """
    return get_queue_stats(queue_name)


@mcp.tool()
def tool_get_dynamodb_health(table_name: str | None = None) -> dict:
    """Get DynamoDB table health for PetAdoptions tables.

    Returns consumed capacity, throttled requests, item count, and table status.

    Args:
        table_name: Optional specific table. Omit it to use the adoptions table:
            the server reads its name from the /petstore/dynamodbtablename SSM
            parameter in the backend account.
    """
    return get_dynamodb_health(table_name)


@mcp.tool()
def tool_get_db_health(cluster_id: str | None = None) -> dict:
    """Get RDS/Aurora cluster health for the PetAdoptions PostgreSQL cluster.

    Returns connections, CPU utilization, read/write latency, deadlocks,
    freeable memory, and buffer cache hit ratio.

    Args:
        cluster_id: Optional Aurora cluster identifier, or a writer/reader
            endpoint hostname to read the identifier from. Omit it to use the
            PetAdoptions cluster: no SSM parameter publishes the identifier, so
            the server reads /petstore/rds-writer-endpoint in the backend
            account and takes the identifier from its first DNS label.
    """
    return get_db_health(cluster_id)


@mcp.tool()
def tool_get_canary_results(canary_name: str | None = None) -> dict:
    """Get CloudWatch Synthetics canary results.

    Returns canary state, schedule, and recent run results including
    pass/fail status and duration.

    Args:
        canary_name: Optional specific canary. If omitted, returns all configured canaries.
    """
    return get_canary_results(canary_name)


@mcp.tool()
def tool_get_recent_alarms(minutes: int = 60) -> dict:
    """Get recent CloudWatch alarm state changes in the backend account.

    Returns current alarm states and recent state-change history, filtered
    to aiops-poc alarms only.

    Args:
        minutes: Lookback window in minutes (default 60).
    """
    return get_recent_alarms(minutes)
