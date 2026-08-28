# agents — self-managed fallback agents (Account OPS)

*For the person replicating this demo in their own accounts: read this to
understand what the two self-managed fallback agents actually do, what they
deliberately cannot do, and which switches you can flip at demo time. Deploy
order and prerequisites live in
[docs/deployment.md](../docs/deployment.md#deployment-order).*

The incident owners are the **AWS DevOps Agent Agent Spaces** (see
[agent-spaces/](../agent-spaces/) and
[docs/aws-devops-agent-integration.md](../docs/aws-devops-agent-integration.md)).
This folder holds the **self-managed fallback estate**: Strands Agents
(Python) on Bedrock AgentCore Runtime that the first responder consults over
**MCP** when the managed chain is inconclusive — plus everything they share.

**Knowledge-only by design:** the fallback agents are knowledge checkers, not
live-telemetry responders — the **platform** DevOps Agent space is the
live-telemetry layer (it holds the BE account association). The backend-agent
consults documented runbooks/playbooks (Agent Skills); the kb-agent checks the
Bedrock KB corpus with citations and escalates to the owning team via SNS.
Neither holds live AWS telemetry tools nor the cross-account BE read role, so
their findings are *documented hypotheses plus the checks the owning team should
run* — never observed fact.

## Where this fits in the deploy

`agents/infra` is the **OPS** account stack and must land after the two
workload stacks (BE overlay, FE) and before `agent-spaces/`. Full order,
prerequisites (CDK bootstrap, Bedrock model access for Claude Sonnet 4.5 +
Titan Text Embeddings V2 in OPS) and the non-CloudFormation script steps are in
[docs/deployment.md](../docs/deployment.md#deployment-order);
`scripts/deploy-all.sh` is the tested path. Two things are easy to miss:

- `scripts/sync-kb.sh` after every `agents/infra` deploy or corpus change, or
  the Knowledge Base stays empty (`deploy-all.sh` runs it for you).
- Confirming the escalation-email SNS subscription, or kb-agent escalations
  never deliver.

## Serving protocol (`SERVE_PROTOCOL`)

Both fallback agents ship as dual-protocol containers, and `SERVE_PROTOCOL`
selects the serving mode at startup (single CMD entrypoint):

| Value | Mode | Contract |
|---|---|---|
| `MCP` (default — **the deployed path**) | FastMCP streamable HTTP, single `investigate` tool wrapping the full investigation | AgentCore MCP contract: `0.0.0.0:8000`, path `/mcp`, stateless |
| `A2A` (**untested alternate**, kept to show the contrast) | A2A server with agent card + `/ping` + `POST /` task endpoint | AgentCore A2A contract: `0.0.0.0:9000`, card at `/.well-known/agent-card.json` |

**Both agent-to-agent links in this demo are MCP.** The fallback link is
registered as `mcpserversigv4` (SigV4 service `bedrock-agentcore`, one
`investigate` tool per agent) by
`scripts/register-fallback-agents-mcp.sh` — that is the one you run. The infra
stack (`agents/infra`) pins `protocolConfiguration 'MCP'` +
`SERVE_PROTOCOL=MCP` on both runtimes to match.

`scripts/register-fallback-agents.sh` registers the same link over A2A
(`remoteagentsigv4`) and is kept for illustration only: **it has never been
run to completion on this deployment** — its registration is blocked by an
account gate with no known exemption process, and it would also need both
runtimes redeployed with `protocolConfiguration 'A2A'` + `SERVE_PROTOCOL=A2A`.
Do not present A2A as the deployed path.

## Contents

| Path | Purpose |
|---|---|
| `backend-agent/` | The `backend-devops-agent` runtime. Served over **MCP** (`investigate` tool); A2A server present but untested. **Knowledge-only**: runbook consultation from Agent Skills — returns documented likely root causes, the checks the owning team should run, and documented remediation guidance. No live telemetry (`src/tools.py` kept on disk as the annotated alternate). Agent card satisfies the DevOps Agent remote-agent requirements (name, description, supportedInterfaces, capabilities, skills). |
| `kb-agent/` | The `backend-kb-agent` runtime, KB flavor. Served over **MCP** (`investigate` tool); A2A app present but untested. **Knowledge-only**: Bedrock Knowledge Base retrieval over the backend architecture corpus with mandatory citations, plus one `escalate_to_owner_team` tool that publishes to the `aiops-poc-escalations` SNS topic. No live telemetry. |
| `kb-corpus/` | Source documents for the Knowledge Base: PetAdoptions architecture summary + agent-safe scenario docs (no runbooks, no fault table). CloudFormation uploads these to the corpus bucket but never ingests them — run `scripts/sync-kb.sh` after every `agents/infra` deploy or corpus change (`deploy-all.sh` does it automatically), or the KB stays empty. |
| `skills/` | Agent Skills ([agentskills.io](https://agentskills.io) format), one folder per runbook (6 today). Loaded directly by the custom agents; for the Agent Spaces the catalog is **split per space** by `skills/manifest.json` (app-team: `frontend-triage` + `report-standards`; platform: the four backend runbooks + `report-standards`), `scripts/package-skills.sh` writes per-space zips to `dist/skills/<space>/`, and `scripts/upload-skills.sh` **uploads them programmatically** as assets of type `skill` (`create-asset` / `update-asset`, verified with `list-assets`); the Operator Web App upload stays documented as a fallback. Profile and region come from `config/accounts.json` → `ops`. One authoring format for both estates. |
| `shared/` | Common code: report schema, skill loader, instrumentation (tool calls, tokens, duration). The BE-scoped boto3 tool wrappers (`aws_tools.py`) are no longer used by the fallback agents (knowledge-only) — kept for reference/alternate use. |
| `infra/` | CDK app (Account OPS): AgentCore runtimes (the 2 fallback agents + the optional diagnostics MCP server), Bedrock Knowledge Base (S3 + S3 Vectors), webhook-bridge Lambda with **dual-path routing** (`aiops-poc-be-infra-*` alarms → platform space webhook, everything else → app-team space webhook) and both webhook secrets, report store (S3), escalation SNS topic, SSM switches, and the `aiops-poc-remote-agent-registration` trust role the MCP registrations use. |

## Runtime switches

| Switch (SSM) | Values | Effect |
|---|---|---|
| `/aiops-poc/peer` | `devops` \| `kb` \| `both` | Which fallback agents `scripts/register-fallback-agents-mcp.sh` registers as MCP capability providers in the first responder's space |
| `/aiops-poc/skills-enabled` | `true` \| `false` | Skills before/after on the custom agents (managed agents use the native per-skill Active/Inactive toggle) |
| `SKILLS_FILTER` (env) | names | Ablation: load only selected skills |

## Escalation (kb-agent only)

The KB agent has one extra tool, `escalate_to_owner_team`, that publishes
its investigation summary to the `aiops-poc-escalations` SNS topic so the
service-owning team gets an email. Configuration:

| Setting | Where | Values / notes |
|---|---|---|
| `ops.escalationEmail` | `config/accounts.json` (git-ignored; placeholder in `config/accounts.json.template`) | Owning-team email that the topic subscription delivers to. Requires a one-time confirmation click after deploy. |
| `ESCALATION_TOPIC_ARN` (env) | Set on the `backend_kb_agent` runtime by `agents/infra` | SNS topic ARN the tool publishes to; if unset the tool returns an error string instead of raising. |
| `ESCALATION_MODE` (env) | Set on the `backend_kb_agent` runtime by `agents/infra` | `always` (default, demo-eager: escalate every investigation so the email reliably arrives) \| `auto` (escalate on probable root cause or low confidence). |

## Guardrails

- Knowledge-only: the fallback agents have no live workload access at all —
  no telemetry tools, and their task role does not hold the cross-account
  BE read role (only the optional diagnostics MCP task role does).
- Investigation-only: the fallback agents must not mutate anything in
  either serving mode (aligned with AWS DevOps Agent guidance for
  capability providers / remote agents). The single deliberate exception:
  the KB agent's `sns:Publish` scoped to only the `aiops-poc-escalations`
  topic — human notification, no workload mutation possible.
- Agents never read `/aiops-poc/active-scenario`.
