# mcp-servers

*For the technical account manager replicating this demo in their own BE / FE /
OPS accounts: after this page you know what the two custom MCP servers in this
repo are, which one is on the demo path (neither is required for it), and what
to set before you run either.*

Both agent-to-agent links in the deployed demo are MCP (`mcpserversigv4`
capability providers): app-team space → platform space, and app-team space → the
two self-managed knowledge agents. A2A registration scripts exist
(`scripts/register-platform-space-agent.sh`,
`scripts/register-fallback-agents.sh`) but are **untested** — do not present A2A
as the deployed path. Background: [docs/a2a-vs-mcp.md](../docs/a2a-vs-mcp.md).

The two servers below are custom MCP servers *we* wrote. Neither is part of the
main narrative: the diagnostics server is descoped, and the operator bridge is a
development scaffold.

| Directory | Runs where | Status |
|---|---|---|
| `backend-diagnostics/` | OPS account, Bedrock AgentCore Runtime (`diagnostics_mcp`) | Deployed and verified live (7 tools over SigV4), but **descoped** from the demo path |
| `operator-bridge/` | Operator's laptop (local stdio) | **Never validated end to end** — 3 of its 5 tools disagree with what the stacks deploy |

All region literals here are `us-east-1`, the default replication region
(`config/accounts.json` → `ops.region`). Account IDs are never hardcoded in this
repo — read them from `config/accounts.json`.

---

## backend-diagnostics/ (OPS account, AgentCore Runtime)

Read-only diagnostics MCP server for the backend domain: FastMCP over
stateless streamable HTTP, bound to `0.0.0.0:8000` with path `/mcp`. Inbound
auth is AgentCore Runtime's own — the runtime has no OAuth/JWT authorizer, so
the data plane accepts **SigV4 only** (service `bedrock-agentcore`). The
container itself has no auth layer.

Deliberately deterministic (no LLM), so it reads as a "remote toolbox" rather
than a second agent. It assumes `aiops-backend-domain-read` in the BE account
via STS; the BE account ID is injected at deploy time as `BE_ACCOUNT_ID` by
`agents/infra` from `config/accounts.json` (`backend.accountId`).

**Descoped from the demo (optional).** The platform DevOps Agent Space's native
account association already gives it live BE telemetry, so the diagnostics
association was removed from the demo path. The runtime stays deployed;
`scripts/register-diagnostics-mcp.sh` re-registers it as an `mcpserversigv4`
capability provider in the **platform** space (all 7 tools) if you want it back.
Registration is account-gated — see the header comment in that script.

| Tool (as exposed) | Arguments | Backing APIs |
|---|---|---|
| `tool_get_service_health` | `service_name` (optional) | ECS running vs desired tasks, deployment status, recent service events |
| `tool_get_lambda_stats` | `minutes` (default 15), `function_name` (optional) | Invocations, errors, average duration, throttles |
| `tool_get_queue_stats` | `queue_name` (optional — name or full queue URL) | Messages visible / in-flight / delayed, age of oldest message |
| `tool_get_dynamodb_health` | `table_name` (optional) | Consumed capacity, throttled requests, item count, table status |
| `tool_get_db_health` | `cluster_id` (optional — identifier or writer/reader endpoint) | Aurora/RDS connections, CPU, read/write latency, deadlocks, buffer cache hit ratio |
| `tool_get_canary_results` | `canary_name` (optional) | Synthetics canary state, schedule, recent run pass/fail and duration |
| `tool_get_recent_alarms` | `minutes` (default 60) | CloudWatch alarm states and state-change history, filtered to `aiops-poc` alarms |

**Generated names are resolved at runtime, not hardcoded.** Four backend
physical names are CloudFormation-generated — the SQS status-update queue, the
adoptions DynamoDB table, the Aurora cluster and the status-updater Lambda — so
no literal in `src/config.py` could be correct in a second account, and there is
none. `src/resource_resolver.py` reads them from the upstream's own `/petstore/*`
SSM contract in the BE account (and, for the status-updater, off the event source
mapping of the queue it consumes), caching each value for the process lifetime.
Resolution order is **caller-supplied argument → SSM → fail**: the four optional
arguments (`queue_name`, `table_name`, `cluster_id`, `function_name`) still win
outright, and `queue_name` / `cluster_id` accept the form the parameters publish
(a queue URL, a writer or reader endpoint). There is deliberately no literal
fallback — an unresolvable name is an error naming the parameter, not a guess.
Which parameter backs which resource is tabulated in
[docs/parameters.md](../docs/parameters.md#names-this-repository-resolves-at-runtime-instead-of-hardcoding)
and [docs/deployment.md](../docs/deployment.md#names-that-are-not-configurable);
the parameters themselves are in [workload/README.md](../workload/README.md).

Local run:

```bash
cd mcp-servers/backend-diagnostics
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
AWS_REGION=us-east-1 BE_ACCOUNT_ID=<BE-account-id> python -m src
```

---

## operator-bridge/ (local, runs in the operator's IDE)

Local **stdio MCP server** that lets an operator poke at the OPS-account
plumbing — the webhook bridge Lambda, the report store, SSM — from Kiro or any
MCP client. Runs with the operator's own credentials for the OPS account (the
profile named by `config/accounts.json` → `ops.profile`); holds no credentials
or state of its own.

**Development scaffold, not a demo path.** It has unit tests but was never
validated against a deployed estate, and three of its five tools do not line up
with what the stacks create. Full detail, including the code fixes needed, is in
[mcp-servers/operator-bridge/README.md](operator-bridge/README.md) and
[docs/operator-ide.md](../docs/operator-ide.md). For a webhook path known to
work end to end, use `scripts/smoke-test.sh` — it builds the SNS-shaped payload
the bridge Lambda actually expects.

| Tool | State |
|---|---|
| `start_investigation(symptom)` | Broken — sends a flat payload; the Lambda iterates `event["Records"]`, so nothing is processed and success is still reported |
| `ask_agent(agent, question)` | Broken — reads a `.../endpoint` SSM parameter the stacks do not publish, then invokes an undeployed Lambda proxy |
| `get_investigation_status(incident_id)` | Broken — looks for `reports/{id}.json`; reports are written under `reports/{YYYY-MM-DD}/{report_id}.json` |
| `get_incident_report(incident_id)` | Broken — same key-prefix mismatch |
| `list_recent_incidents()` | Works — lists objects under the `reports/` prefix |

Kiro setup (`.kiro/settings/mcp.json`). `AWS_REGION` is **required** — the
bridge refuses to start without it, rather than defaulting to a region that
would silently read the wrong estate. `REPORTS_BUCKET` is optional: when it is
absent the bridge asks your own credentials which account they are in and uses
`aiops-poc-reports-<that-account>`, which is what `agents/infra` creates. Set it
explicitly only if your reports live somewhere else.

```json
{
  "mcpServers": {
    "aiops-operator": {
      "command": "python",
      "args": ["-m", "server"],
      "cwd": "mcp-servers/operator-bridge",
      "env": {
        "AWS_PROFILE": "<ops.profile>",
        "AWS_REGION": "us-east-1",
        "REPORTS_BUCKET": "aiops-poc-reports-<OPS-account-id>"
      }
    }
  }
}
```

Your OPS account ID is in `config/accounts.json` (`ops.accountId`), or read the
bucket name back:

```bash
aws s3 ls --profile <ops.profile> --region us-east-1 | grep aiops-poc-reports
```
