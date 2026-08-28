"""
Operator Bridge — Local stdio MCP server for IDE integration.

Exposes investigation tools to the operator (Kiro/VSCode) using the
operator's own AWS credentials. No cross-account role assumption; all
operations target the monitoring (OPS) account in the configured region,
supplied by the operator's mcp.json from config/accounts.json → ops.profile
and ops.region. No account identifier or region is written here.
"""

from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any

import boto3
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

# ---------------------------------------------------------------------------
# Configuration (from environment; the region has no fallback)
# ---------------------------------------------------------------------------

# Region: required, with no literal fallback (Requirement 5.4). The operator's
# mcp.json supplies it from config/accounts.json → ops.region; see
# docs/operator-ide.md. This is not a _require_env variable because nothing in
# CDK populates a local IDE server's environment — the failure message names
# the operator's own config instead of a stack.
REGION = (
    os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or ""
).strip()
if not REGION:
    raise RuntimeError(
        "AWS_REGION is not set. The operator's mcp.json supplies it from "
        "config/accounts.json → ops.region; see docs/operator-ide.md."
    )
WEBHOOK_SECRET_ID = os.environ.get("WEBHOOK_SECRET_ID", "aiops-poc/webhook-credentials")
SSM_PREFIX = os.environ.get("SSM_PREFIX", "/aiops-poc")

# Reports bucket: no literal default, for the same reason the region has none.
# `agents/infra` creates `aiops-poc-reports-<ops-account>`, so the old
# unsuffixed default `aiops-poc-reports` named a bucket that exists in no
# deployment — and because S3 bucket names are one global namespace, reading or
# writing against an unsuffixed guess either fails or touches a bucket somebody
# else owns. REPORTS_BUCKET from the operator's mcp.json still wins; when it is
# absent the operator's own credentials are asked which account they are in,
# which is the one derivation that cannot be stale. Resolved lazily and cached:
# an import must not make an AWS call. Mirrors _resolve_report_bucket() in
# agents/shared/report.py — KEEP THE TWO IN SYNC.
REPORTS_BUCKET_PREFIX = "aiops-poc-reports"
_reports_bucket: str | None = None

# ---------------------------------------------------------------------------
# AWS client helpers
# ---------------------------------------------------------------------------


def _get_boto_session() -> boto3.Session:
    """Create a boto3 session using the operator's local credentials."""
    profile = os.environ.get("AWS_PROFILE")
    return boto3.Session(region_name=REGION, profile_name=profile)


def _s3_client():
    return _get_boto_session().client("s3")


def _ssm_client():
    return _get_boto_session().client("ssm")


def _secrets_client():
    return _get_boto_session().client("secretsmanager")


def _lambda_client():
    return _get_boto_session().client("lambda")


def reports_bucket() -> str:
    """Return the reports bucket: REPORTS_BUCKET, else derived from the caller.

    Cached for the process — the name cannot change while the bridge runs.
    """
    global _reports_bucket

    configured = os.environ.get("REPORTS_BUCKET", "").strip()
    if configured:
        return configured

    if _reports_bucket is not None:
        return _reports_bucket

    try:
        account = _get_boto_session().client("sts").get_caller_identity()["Account"]
    except Exception as exc:
        raise RuntimeError(
            "REPORTS_BUCKET is not set and the account it would be derived from "
            f"could not be read ({type(exc).__name__}: {exc}). agents/infra "
            f"creates {REPORTS_BUCKET_PREFIX}-<ops-account-id>; set REPORTS_BUCKET "
            "in the operator's mcp.json, or check that ops.profile from "
            "config/accounts.json has valid credentials. See docs/operator-ide.md."
        ) from exc

    _reports_bucket = f"{REPORTS_BUCKET_PREFIX}-{account}"
    return _reports_bucket


# ---------------------------------------------------------------------------
# MCP Server definition
# ---------------------------------------------------------------------------

app = Server("aiops-operator-bridge")


@app.list_tools()
async def list_tools() -> list[Tool]:
    """Expose the five operator tools."""
    return [
        Tool(
            name="start_investigation",
            description=(
                "Start a new incident investigation by publishing a business "
                "symptom to the app-team webhook (same path as a real alarm). "
                "Returns the investigation/incident ID."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "symptom": {
                        "type": "string",
                        "description": "Business symptom description, e.g. 'checkout latency p99 > 2s'",
                    },
                },
                "required": ["symptom"],
            },
        ),
        Tool(
            name="ask_agent",
            description=(
                "Send a follow-up question to a specified agent (devops or kb). "
                "Returns the agent's response."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "agent": {
                        "type": "string",
                        "description": "Agent identifier: 'devops' or 'kb'",
                        "enum": ["devops", "kb"],
                    },
                    "question": {
                        "type": "string",
                        "description": "The question or follow-up to send to the agent",
                    },
                },
                "required": ["agent", "question"],
            },
        ),
        Tool(
            name="get_investigation_status",
            description=(
                "Get the current status of a running or completed investigation."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "incident_id": {
                        "type": "string",
                        "description": "The incident/investigation ID to check",
                    },
                },
                "required": ["incident_id"],
            },
        ),
        Tool(
            name="get_incident_report",
            description=(
                "Fetch the full structured report for a completed investigation "
                "from the S3 report store."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "incident_id": {
                        "type": "string",
                        "description": "The incident/investigation ID whose report to fetch",
                    },
                },
                "required": ["incident_id"],
            },
        ),
        Tool(
            name="list_recent_incidents",
            description=(
                "List recent incidents/investigations with summary info "
                "(id, status, symptom, timestamp)."
            ),
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    """Dispatch tool calls to their implementations."""
    match name:
        case "start_investigation":
            return await _start_investigation(arguments["symptom"])
        case "ask_agent":
            return await _ask_agent(arguments["agent"], arguments["question"])
        case "get_investigation_status":
            return await _get_investigation_status(arguments["incident_id"])
        case "get_incident_report":
            return await _get_incident_report(arguments["incident_id"])
        case "list_recent_incidents":
            return await _list_recent_incidents()
        case _:
            return [TextContent(type="text", text=f"Unknown tool: {name}")]


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------


async def _start_investigation(symptom: str) -> list[TextContent]:
    """
    Start an investigation by invoking the webhook bridge Lambda directly.

    In production this would hit the actual webhook endpoint. For the PoC we
    invoke the bridge Lambda directly (same effect, simpler auth from local).
    The Lambda function name is stored in SSM.
    """
    incident_id = f"INC-{uuid.uuid4().hex[:8].upper()}"
    timestamp = datetime.now(timezone.utc).isoformat()

    # Build the alarm-like payload the webhook bridge expects
    payload = {
        "source": "operator-bridge",
        "incident_id": incident_id,
        "symptom": symptom,
        "timestamp": timestamp,
    }

    try:
        # Try to invoke the webhook bridge Lambda
        ssm = _ssm_client()
        param = ssm.get_parameter(Name=f"{SSM_PREFIX}/webhook-bridge-function")
        function_name = param["Parameter"]["Value"]

        lam = _lambda_client()
        lam.invoke(
            FunctionName=function_name,
            InvocationType="Event",  # async — don't block
            Payload=json.dumps(payload).encode(),
        )
    except Exception as exc:
        # If the Lambda isn't deployed yet, still return the incident_id
        # so the operator knows what was attempted
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "incident_id": incident_id,
                        "status": "trigger_failed",
                        "error": str(exc),
                        "symptom": symptom,
                        "timestamp": timestamp,
                    },
                    indent=2,
                ),
            )
        ]

    return [
        TextContent(
            type="text",
            text=json.dumps(
                {
                    "incident_id": incident_id,
                    "status": "investigation_started",
                    "symptom": symptom,
                    "timestamp": timestamp,
                },
                indent=2,
            ),
        )
    ]


async def _ask_agent(agent: str, question: str) -> list[TextContent]:
    """
    Send a follow-up question to a specified fallback agent via the
    AgentCore A2A endpoint. Uses the agent's endpoint URL from SSM.
    """
    try:
        ssm = _ssm_client()
        param = ssm.get_parameter(Name=f"{SSM_PREFIX}/agents/{agent}/endpoint")
        endpoint_url = param["Parameter"]["Value"]
    except Exception as exc:
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "agent": agent,
                        "status": "error",
                        "error": f"Could not resolve agent endpoint: {exc}",
                    },
                    indent=2,
                ),
            )
        ]

    # For the PoC, we invoke via the Lambda-based A2A proxy
    # In production this would be a direct A2A HTTP call
    try:
        lam = _lambda_client()
        payload = {
            "agent": agent,
            "question": question,
            "endpoint": endpoint_url,
        }
        response = lam.invoke(
            FunctionName=f"aiops-poc-agent-proxy-{agent}",
            InvocationType="RequestResponse",
            Payload=json.dumps(payload).encode(),
        )
        result = json.loads(response["Payload"].read().decode())
        return [TextContent(type="text", text=json.dumps(result, indent=2))]
    except Exception as exc:
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "agent": agent,
                        "status": "error",
                        "error": str(exc),
                        "question": question,
                    },
                    indent=2,
                ),
            )
        ]


async def _get_investigation_status(incident_id: str) -> list[TextContent]:
    """
    Check the status of an investigation. Status is tracked via the
    report object in S3 — if a report exists it's complete, otherwise
    we check SSM for in-progress state.
    """
    s3 = _s3_client()

    # Check if a completed report exists
    try:
        s3.head_object(Bucket=reports_bucket(), Key=f"reports/{incident_id}.json")
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {"incident_id": incident_id, "status": "completed"},
                    indent=2,
                ),
            )
        ]
    except s3.exceptions.ClientError as e:
        if e.response["Error"]["Code"] != "404":
            return [
                TextContent(
                    type="text",
                    text=json.dumps(
                        {
                            "incident_id": incident_id,
                            "status": "error",
                            "error": str(e),
                        },
                        indent=2,
                    ),
                )
            ]

    # No report yet — check for in-progress marker
    try:
        ssm = _ssm_client()
        param = ssm.get_parameter(Name=f"{SSM_PREFIX}/investigations/{incident_id}/status")
        status = param["Parameter"]["Value"]
    except Exception:
        status = "unknown"

    return [
        TextContent(
            type="text",
            text=json.dumps(
                {"incident_id": incident_id, "status": status},
                indent=2,
            ),
        )
    ]


async def _get_incident_report(incident_id: str) -> list[TextContent]:
    """Fetch the full structured report JSON from the S3 report store."""
    s3 = _s3_client()

    try:
        response = s3.get_object(
            Bucket=reports_bucket(), Key=f"reports/{incident_id}.json"
        )
        report_body = response["Body"].read().decode("utf-8")
        report = json.loads(report_body)
        return [TextContent(type="text", text=json.dumps(report, indent=2))]
    except Exception as exc:
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {
                        "incident_id": incident_id,
                        "status": "error",
                        "error": str(exc),
                    },
                    indent=2,
                ),
            )
        ]


async def _list_recent_incidents() -> list[TextContent]:
    """List recent incidents by scanning the S3 reports prefix."""
    s3 = _s3_client()

    try:
        response = s3.list_objects_v2(
            Bucket=reports_bucket(),
            Prefix="reports/",
            MaxKeys=20,
        )

        incidents = []
        for obj in response.get("Contents", []):
            key = obj["Key"]
            # Extract incident_id from key pattern reports/{id}.json
            if key.endswith(".json"):
                incident_id = key.removeprefix("reports/").removesuffix(".json")
                incidents.append(
                    {
                        "incident_id": incident_id,
                        "last_modified": obj["LastModified"].isoformat(),
                        "size_bytes": obj["Size"],
                    }
                )

        # Sort by most recent first
        incidents.sort(key=lambda x: x["last_modified"], reverse=True)

        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {"incidents": incidents, "count": len(incidents)},
                    indent=2,
                ),
            )
        ]
    except Exception as exc:
        return [
            TextContent(
                type="text",
                text=json.dumps(
                    {"status": "error", "error": str(exc)},
                    indent=2,
                ),
            )
        ]


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


async def main():
    """Run the server over stdio."""
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    import asyncio

    asyncio.run(main())
