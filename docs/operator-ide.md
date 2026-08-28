# Operator IDE access — Kiro integration

*For the technical account manager replicating this demo in their own BE / FE /
OPS accounts: after this page you can drive an investigation from your editor —
either against the managed `app-team` Agent Space (the tested path) or against
the local operator bridge (development only, with the known gaps called out
below).*

Two paths connect an operator's IDE (Kiro / VSCode) to the AI Ops
investigation estate. Both are MCP; they differ in transport and in what they
talk to.

| Path | Estate | Transport | Auth | Status | Best for |
|---|---|---|---|---|---|
| AWS DevOps Agent Kiro Power | Managed (Agent Spaces) | Remote MCP endpoint | Access token or SigV4 | Recommended | Demos and day-to-day operations |
| Operator Bridge (`mcp.json`) | Custom (fallback agents, report store) | Local stdio | Operator's AWS credentials | Development scaffold, **not** validated end to end | Poking at the OPS-account plumbing |

Use the managed path for anything you intend to show. The bridge is useful for
inspecting the OPS-side plumbing from the editor, but three of its five tools
do not line up with what the rest of the repo deploys — see
[Known gaps in the bridge](#known-gaps-in-the-bridge) before you rely on it.

This page hardcodes no region and no account ID. Everything that varies is named
by its JSON path in `config/accounts.json`, so set these handles once per session
and the commands below are copy-pasteable as-is:

```bash
OPS_PROFILE=$(jq -r '.ops.profile' config/accounts.json)
OPS_REGION=$(jq -r '.ops.region' config/accounts.json)
OPS_ACCOUNT=$(jq -r '.ops.accountId' config/accounts.json)
REPORTS_BUCKET="aiops-poc-reports-${OPS_ACCOUNT}"   # agents/infra suffixes the bucket
```

Use one region for all three accounts — the demo has not been validated split
across regions.

---

## Path 1 — Managed estate (AWS DevOps Agent Kiro Power)

The official **AWS DevOps Agent** Kiro power connects directly to the
`app-team` Agent Space's remote MCP endpoint. This is the recommended path — it
puts the operator on the same first-responder chain the alarms use (triage →
MCP capability providers: the `platform` space and the two self-managed
knowledge agents). Both of those hops are MCP (`mcpserversigv4`), not A2A; see
[aws-devops-agent-integration.md](aws-devops-agent-integration.md) for the
registration details.

### Install / enable the power

1. Open Kiro's power manager (Cmd+Shift+P → "Kiro: Manage Powers").
2. Search for **AWS DevOps Agent**.
3. Click **Install** (or **Enable** if already installed).

### Configuration

The power needs two values — set them in the power's settings or as
environment variables:

| Setting | Env var | Value |
|---|---|---|
| Region | `DEVOPS_AGENT_REGION` | the region your OPS account's spaces live in — `config/accounts.json` → `ops.region` |
| Access token | `DEVOPS_AGENT_TOKEN` | Access token from the Operator Web App (scoped `read`/`operate`, client type `human`, recommended 7-day expiry) |

> `DEVOPS_AGENT_TOKEN` is a bearer credential and stays **environment-only**. It
> is deliberately not a `config/accounts.json` field, not even in the git-ignored
> copy: that file gets copied between machines, diffed, and pasted into chats.
> Keep the token in your shell environment or the power's own settings store, and
> rotate it rather than sharing it.

**Endpoint pattern** (resolved by the power internally):

```
https://connect.aidevops.{region}.api.aws/mcp
```

`{region}` is `ops.region`.

### Alternative: SigV4 authentication

If your environment uses IAM instead of access tokens, configure the power to
use SigV4 credentials for your OPS account. The IAM principal needs the
`AIDevOpsAgentAccessPolicy` managed policy attached — the `agent-spaces/` stack
creates exactly such a role (the OPS monitor role) that you can assume. Look up
your OPS account ID in `config/accounts.json` (`ops.accountId`); it is never
hardcoded in this repo.

### Available tools

Once connected, the power exposes the Agent Space's built-in investigation
tools. Names come from the power version you install — expect this shape:

| Tool | Description |
|---|---|
| `investigate` | Start an async investigation (5–8 min). The first responder triages the FE domain and may call its MCP capability providers: the `platform` space and the two self-managed knowledge agents |
| `chat` | Send follow-up questions to the first responder |
| `get_status` | Check investigation progress |
| `list_investigations` | List recent investigations and their outcomes |

> **Set expectations before you demo.** In all five recorded `payments-crash`
> runs the app-team responder called the self-managed knowledge agents and
> **never** delegated to the `platform` space. If you want to show
> space-to-space delegation, force it explicitly and check the traces — see
> "What the recorded runs show" in
> [aws-devops-agent-integration.md](aws-devops-agent-integration.md).

### Creating an access token

1. Open the **Operator Web App** for the `app-team` space. The
   `agent-spaces/` stack stores the URL in SSM — read it rather than typing it:

   ```bash
   aws ssm get-parameter \
     --name /aiops-poc/agent-spaces/app-team/operator-app-url \
     --query Parameter.Value --output text \
     --profile "$OPS_PROFILE" --region "$OPS_REGION"
   ```

2. Click **Settings → Access Tokens → Create Token**.
3. Select scope: `read` + `operate`, client type: `human`, expiry: 7 days.
4. Copy the token — it is shown only once.

> Signing in to the Operator Web App requires your federation identifier to be
> entered once per space in the console (Operator Access tab) — it cannot be set
> by CDK. See `agent-spaces/README.md` and `operator.federationIdentifier` in
> `config/accounts.json`.

---

## Path 2 — Custom estate (Operator Bridge)

The operator bridge (`mcp-servers/operator-bridge/server.py`) is a local stdio
MCP server that talks to the OPS-account plumbing — the webhook bridge Lambda,
the report store, and SSM — using the operator's own AWS credentials. No
cross-account role assumption is needed; all calls target the OPS account.

### Known gaps in the bridge

The bridge has unit tests but was never validated against a deployed estate.
Three of its five tools disagree with what the stacks actually create, so treat
this path as a scaffold. These need **code** fixes, not doc fixes:

| Tool | Gap |
|---|---|
| `start_investigation` | Invokes the webhook bridge Lambda with a flat `{source, incident_id, symptom, timestamp}` payload, but `agents/infra/lambda/webhook-bridge/handler.py` iterates `event["Records"]` (SNS envelope). A flat payload processes zero records, so no investigation is created |
| `ask_agent` | Reads `/aiops-poc/agents/{agent}/endpoint` (the stacks publish `.../runtime-arn` and `.../runtime-id` under names `backend-devops-agent` / `backend-kb-agent`) and then invokes a Lambda `aiops-poc-agent-proxy-{agent}` that nothing in this repo deploys |
| `get_investigation_status`, `get_incident_report` | Look for `reports/{incident_id}.json`, but `agents/shared/report.py` writes `reports/{YYYY-MM-DD}/{report_id}.json`, so real reports are never found. `list_recent_incidents` still lists objects fine |

For a webhook path that is known to work end to end, use
`scripts/smoke-test.sh` (it builds the SNS-shaped payload the handler expects).

### Prerequisites

- Python 3.11+
- AWS credentials configured for the OPS profile (`config/accounts.json` →
  `ops.profile`, `monitoring` by default)
- The operator bridge package installed locally:

```bash
pip install -e mcp-servers/operator-bridge
```

### `mcp.json` configuration

Add the following to your workspace `.kiro/mcp.json` (Kiro) or
`.vscode/mcp.json` (VSCode):

`mcp.json` takes literals, not shell variables, so paste the resolved values —
each one from a JSON path in `config/accounts.json`:

```json
{
  "mcpServers": {
    "aiops-operator-bridge": {
      "command": "python",
      "args": ["-m", "server"],
      "cwd": "mcp-servers/operator-bridge",
      "env": {
        "AWS_PROFILE": "<ops.profile>",
        "AWS_REGION": "<ops.region>",
        "REPORTS_BUCKET": "aiops-poc-reports-<ops.accountId>"
      }
    }
  }
}
```

> **`AWS_REGION` and `REPORTS_BUCKET` both have to be set here.** `server.py`
> requires `AWS_REGION` (or `AWS_DEFAULT_REGION`) and refuses to start without
> it — there is no fallback region, by design, so a bridge can never silently
> query the wrong one. `REPORTS_BUCKET` does have a default, and that default is
> wrong for every replication: `agents/infra` creates the bucket with the OPS
> account ID as a suffix. Read the name back if you would rather not type it:
>
> ```bash
> aws s3 ls --profile "$OPS_PROFILE" --region "$OPS_REGION" | grep aiops-poc-reports
> ```

### Available tools

| Tool | Parameters | Description |
|---|---|---|
| `start_investigation` | `symptom` (string) | Intended to trigger an investigation by invoking the webhook bridge Lambda with an alarm-like payload; returns an incident ID. Payload shape gap above. |
| `ask_agent` | `agent` ("devops" \| "kb"), `question` (string) | Intended to put a knowledge question to one of the self-managed fallback agents. Those agents are knowledge-only (runbook / KB consultation) with no live AWS access, so ask documented-knowledge questions, not live metric values. Note the managed estate reaches these same agents as MCP capability providers (single `investigate` tool); the bridge instead expects an undeployed Lambda proxy. |
| `get_investigation_status` | `incident_id` (string) | Checks whether the investigation is in progress or completed (looks for the report in S3). Key-prefix gap above. |
| `get_incident_report` | `incident_id` (string) | Fetches the full structured report JSON from the S3 report store. Key-prefix gap above. |
| `list_recent_incidents` | _(none)_ | Lists up to 20 objects under the `reports/` prefix (id, last modified, size). |

### Environment variables

| Variable | Default in `server.py` | Purpose |
|---|---|---|
| `AWS_PROFILE` | _(none)_ | Named profile for the OPS account — `ops.profile` |
| `AWS_REGION` | _(none — startup fails without it)_ | Target region — `ops.region` |
| `REPORTS_BUCKET` | _(none — derived as `aiops-poc-reports-<caller's account>`)_ | S3 bucket storing investigation reports. Set it only if your reports live outside the account your credentials are in |
| `WEBHOOK_SECRET_ID` | `aiops-poc/webhook-credentials` | Secrets Manager secret for webhook HMAC |
| `SSM_PREFIX` | `/aiops-poc` | SSM parameter prefix |

---

## Walkthrough — End-to-end operator flow

### Using the managed estate (Kiro Power)

1. **Start an investigation from a symptom:**

   ```
   Prompt: "Investigate: checkout latency p99 > 2s for the last 10 minutes"
   ```

   Kiro calls `investigate` on the `app-team` space. The first responder
   begins triaging the FE domain.

2. **Check progress (after 1–2 minutes):**

   ```
   Prompt: "What's the status of the current investigation?"
   ```

   Kiro calls `get_status`. Typical response in the recorded runs: triage of
   the FE tier, then a consult of the backend runbook/KB agents with
   `payforadoption` as the suspected service.

3. **Ask a follow-up:**

   ```
   Prompt: "Is there any correlation with DynamoDB throttling events?"
   ```

   Kiro calls `chat` with your question. The first responder incorporates
   the context into its analysis.

4. **Review the outcome (after 5–8 minutes):**

   ```
   Prompt: "Show me the final investigation report"
   ```

   Kiro calls `list_investigations` then retrieves the relevant report with
   business impact, root cause, confidence, evidence timeline, and
   remediation suggestions.

### Using the custom estate (Operator Bridge)

The payloads below are the shapes the bridge is designed to return. Until the
gaps in [Known gaps in the bridge](#known-gaps-in-the-bridge) are fixed in code,
expect `start_investigation` to report success without an investigation being
created, `ask_agent` to return an error, and the two report tools to miss real
reports.

1. **Start an investigation:**

   ```
   Prompt: "Start an investigation for symptom: search service returning 503 errors"
   ```

   Kiro calls `start_investigation(symptom="search service returning 503 errors")`.
   Response:
   ```json
   {
     "incident_id": "INC-A1B2C3D4",
     "status": "investigation_started",
     "symptom": "search service returning 503 errors",
     "timestamp": "2026-07-15T14:32:00+00:00"
   }
   ```

2. **Check the status:**

   ```
   Prompt: "Check status of INC-A1B2C3D4"
   ```

   Kiro calls `get_investigation_status(incident_id="INC-A1B2C3D4")`.
   Response: `{ "incident_id": "INC-A1B2C3D4", "status": "in_progress" }`

3. **Ask the KB agent a question while waiting:**

   ```
   Prompt: "Ask the kb agent: what services depend on petsearch?"
   ```

   Kiro calls `ask_agent(agent="kb", question="what services depend on petsearch?")`.
   The KB agent retrieves from the architecture corpus and responds with
   cited facts.

4. **Fetch the completed report:**

   ```
   Prompt: "Get the report for INC-A1B2C3D4"
   ```

   Kiro calls `get_incident_report(incident_id="INC-A1B2C3D4")`.
   Returns the full structured report: business impact, root cause, fault ID,
   confidence, evidence timeline, remediation, and telemetry
   (round trips, tokens, duration, tool calls).

5. **List all recent incidents:**

   ```
   Prompt: "List recent incidents"
   ```

   Kiro calls `list_recent_incidents()` and shows the 20 most recent
   investigations sorted by timestamp.

---

## Troubleshooting

### Credentials / authentication

| Symptom | Likely cause | Fix |
|---|---|---|
| `ExpiredTokenException` from the Kiro power | Access token expired | Create a new token in the Operator Web App (Settings → Access Tokens) |
| `AccessDeniedException` with SigV4 | IAM principal missing the monitor role policy | Attach `AIDevOpsAgentAccessPolicy` to your role in the OPS account |
| `NoCredentialsError` from the bridge | `AWS_PROFILE` not set or profile not configured | Verify `~/.aws/config` has the `ops.profile` profile with valid credentials |
| `ExpiredToken` / `InvalidIdentityToken` from the bridge | Session for the OPS profile expired | Refresh however your org issues credentials (e.g. `aws sso login --profile "$OPS_PROFILE"`), then `aws sts get-caller-identity --profile "$OPS_PROFILE"` |
| `RuntimeError: AWS_REGION is not set` at bridge startup | No region in the `mcp.json` `env` block; `server.py` has no fallback | Set `AWS_REGION` to `ops.region` |
| Tools return empty results with valid credentials | `AWS_REGION` set to a region you did not deploy to | Match it to `ops.region`; all three accounts use one region |

### Missing infrastructure

| Symptom | Likely cause | Fix |
|---|---|---|
| `ParameterNotFound: /aiops-poc/webhook-bridge-function` | Agent platform not deployed | Run `scripts/deploy-all.sh` or deploy `agents/infra` separately |
| `NoSuchBucket: aiops-poc-reports-<id>` | The bridge derived the name from the account your credentials are in, and no reports bucket exists there — usually the wrong profile, or `agents/infra` not deployed | Check `AWS_PROFILE` points at OPS, then deploy `agents/infra`: `(cd agents/infra && npx cdk deploy --profile "$OPS_PROFILE")`. Set `REPORTS_BUCKET` explicitly if the bucket lives in another account |
| `ResourceNotFoundException` on Lambda invoke | Webhook bridge Lambda not deployed | Deploy `agents/infra`; check the function name matches SSM |

### Empty or missing reports

| Symptom | Likely cause | Fix |
|---|---|---|
| `get_incident_report` returns 404 for a report you can see in S3 | The bridge looks under `reports/{id}.json`; reports are written under `reports/{date}/{id}.json` | Known code gap — fetch it directly meanwhile: `aws s3 ls "s3://${REPORTS_BUCKET}/reports/" --recursive --profile "$OPS_PROFILE" --region "$OPS_REGION"` |
| `get_incident_report` returns 404 and no object exists | Investigation still running, or agent timed out | Check status first; if it timed out, review agent logs in CloudWatch |
| `list_recent_incidents` returns `count: 0` | No investigations have completed yet, or wrong bucket/region | Confirm `REPORTS_BUCKET` and `AWS_REGION`, then trigger a run with `scripts/smoke-test.sh` and wait 5–8 min |
| Report has `confidence: low` | Agent hit 10-min timeout or lacked skills | Enable skills (`/aiops-poc/skills-enabled = true`), ensure load gen is running |

### Bridge server won't start

| Symptom | Likely cause | Fix |
|---|---|---|
| `ModuleNotFoundError: mcp` | Package not installed | `pip install -e mcp-servers/operator-bridge` |
| `ModuleNotFoundError: server` | Wrong working directory | Ensure `cwd` in `mcp.json` points to `mcp-servers/operator-bridge` |
| Python version error | Python < 3.11 | Install Python 3.11+ and update the `command` in `mcp.json` if needed |
