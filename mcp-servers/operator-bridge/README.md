# Operator Bridge — Local stdio MCP Server

*For the technical account manager replicating this demo in their own BE / FE /
OPS accounts: after this page you can run the bridge against your own OPS
account, and you know which of its tools work and which are scaffolding that
needs a code fix first.*

Local MCP server for IDE integration (Kiro / VSCode). It talks to the
OPS-account plumbing — the webhook bridge Lambda, the report store in S3, and
SSM — with the operator's own credentials. No cross-account role assumption; all
calls target the OPS account.

> **Status: development scaffold, not validated end to end.** The bridge has unit
> tests but was never run against a deployed estate, and three of its five tools
> disagree with what the stacks create (details below). For the operator path
> that is tested, use the AWS DevOps Agent Kiro power against the `app-team`
> Agent Space — see [docs/operator-ide.md](../../docs/operator-ide.md).

Region literals on this page are `us-east-1`, the default replication region
(`config/accounts.json` → `ops.region`). Substitute your own if you deploy
elsewhere.

## Tools

| Tool | Description | State |
|------|-------------|-------|
| `start_investigation(symptom)` | Intended to trigger an investigation by invoking the webhook bridge Lambda with an alarm-like payload; returns an incident ID | **Broken** (payload shape) |
| `ask_agent(agent, question)` | Intended to put a knowledge question to one of the self-managed agents (`devops` / `kb`) | **Broken** (endpoint + proxy) |
| `get_investigation_status(incident_id)` | Checks whether a report exists in S3, else reads an SSM in-progress marker | **Broken** (report key prefix) |
| `get_incident_report(incident_id)` | Fetches the structured report JSON from the report store | **Broken** (report key prefix) |
| `list_recent_incidents()` | Lists up to 20 objects under the `reports/` prefix (id, last modified, size) | Works |

### Known gaps (need code fixes, not doc fixes)

| Tool | Gap |
|---|---|
| `start_investigation` | Invokes the bridge Lambda with a flat `{source, incident_id, symptom, timestamp}` payload, but `agents/infra/lambda/webhook-bridge/handler.py` iterates `event["Records"]` (an SNS envelope). A flat payload processes zero records: no investigation is created, yet the tool still reports `investigation_started` |
| `ask_agent` | Reads `/aiops-poc/agents/{agent}/endpoint`, which nothing publishes — `agents/infra` publishes `/aiops-poc/agents/{backend-devops-agent\|backend-kb-agent\|diagnostics-mcp}/runtime-arn` and `.../runtime-id`. It then invokes a Lambda `aiops-poc-agent-proxy-{agent}` that no stack in this repo deploys. In the deployed demo those two agents are reached as MCP capability providers (`mcpserversigv4`) of the `app-team` space, each exposing a single `investigate` tool |
| `get_investigation_status`, `get_incident_report` | Look for `reports/{incident_id}.json`, but `agents/shared/report.py` writes `reports/{YYYY-MM-DD}/{report_id}.json`, so real reports are never found |

For a webhook path known to work end to end, use `scripts/smoke-test.sh` — it
builds the SNS-shaped payload the handler expects.

## Setup

```bash
cd mcp-servers/operator-bridge
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

Requires Python 3.11+ and credentials for the OPS account (the profile named by
`config/accounts.json` → `ops.profile`).

## Kiro / mcp.json configuration

Add this to your workspace `.kiro/settings/mcp.json` (Kiro) or `.vscode/mcp.json`
(VSCode). The `cwd` matters — `server.py` is imported as a top-level module:

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

> **`AWS_REGION` is required; `REPORTS_BUCKET` is not.** `server.py` refuses to
> start without a region rather than defaulting to one that would silently read
> the wrong estate. The bucket has no literal default either: `agents/infra`
> creates `aiops-poc-reports-${account}`, so when `REPORTS_BUCKET` is absent the
> bridge asks your own credentials which account they are in and derives the name
> from that. Set it explicitly only if your reports live elsewhere. To read the
> name back:
>
> ```bash
> aws s3 ls --profile <ops.profile> --region us-east-1 | grep aiops-poc-reports
> ```

## Running tests

```bash
source .venv/bin/activate
pytest tests/ -v
```

The tests exercise the tool implementations against mocked AWS APIs, so they
pass regardless of the gaps listed above.

## Environment variables

| Variable | Default in `server.py` | Description |
|----------|---------|-------------|
| `AWS_PROFILE` | _(none)_ | Named profile for the OPS account; supply `ops.profile` from `config/accounts.json` |
| `AWS_REGION` | _(none — **required**, startup fails without it)_ | Region for all API calls; supply `ops.region` from `config/accounts.json` |
| `REPORTS_BUCKET` | _(none — derived as `aiops-poc-reports-<caller's account>`)_ | S3 bucket for incident reports |
| `SSM_PREFIX` | `/aiops-poc` | SSM parameter prefix |
| `WEBHOOK_SECRET_ID` | `aiops-poc/webhook-credentials` | Secrets Manager secret for webhook HMAC (matches the app-team secret created by `agents/infra`) |
