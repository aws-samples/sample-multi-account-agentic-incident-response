# scripts — bootstrap and deploy helpers

| Script | Purpose |
|---|---|
| `setup-config.sh` | Create `config/accounts.json`: prompts for every input the template declares as required, validates each one, then hands off to `preflight.sh` for the verdict. This is the first step — `bootstrap.sh` and `deploy-all.sh` both need the file to exist already. |
| `preflight.sh` | Read-only gate, no AWS calls: prints every resolved input with its origin and fails on a missing or still-placeholder required value, on the three accounts disagreeing about the region, or on a stale `cdk.context.json`. Also warns when the local AWS CLI cannot resolve `aws devops-agent` or its asset operations (P6) and when no Docker daemon is reachable (P7 — the image builds in `deploy-all.sh` steps 3-4 need it, and step 3 is only reached after the 45-90 min upstream deploy). `--strict` promotes both warnings to failures. `bootstrap.sh` and `deploy-all.sh` run it first. |
| `bootstrap.sh` | `cdk bootstrap` all three accounts (or one with `--account be\|fe\|ops`), after `preflight.sh`. Uses CDK's default qualifier (`hnb659fds`), the one the four CDK apps pin; reads each account's existing `CDKToolkit` stack first and refuses (exit 99) when it belongs to a different qualifier, since updating it in place would delete that qualifier's staging roles ([why](../docs/deployment.md#troubleshooting-two-cdk-toolkit-stacks-in-one-account)). Nothing else: it does not create `config/accounts.json` (that is `setup-config.sh`, and this script fails without the file) and it does not check Bedrock model access (a console step on the [manual steps checklist](../docs/deployment.md#5-manual-steps-checklist-not-scripted)). |
| `sync-outputs.sh` | Sync cross-account values (workload SSM exports → ops account; agent runtime ARNs → operator bridge config). |
| `deploy-all.sh` | Full ordered deployment: upstream workload → overlay → agent platform. |
| `sync-kb.sh` | Start a Bedrock Knowledge Base ingestion job for the corpus data source and poll to completion. CloudFormation creates the KB but never ingests, so this must run after every `agents/infra` deploy and after any `agents/kb-corpus/` change (`deploy-all.sh` calls it automatically in step 4). Idempotent. |
| `smoke-test.sh` | Two causal checks: fire a synthetic webhook and confirm the managed-estate investigation started; invoke each selected fallback agent's `investigate` over SigV4 and validate the returned report plus its S3 archive. |
| `../chaos/scripts/trigger-alarm.sh` | **Deterministic demo lever.** Force a business SLO alarm OK→ALARM via the documented CloudWatch `set-alarm-state` testing API to fire the webhook → first-responder investigation chain without injecting a real fault (auto-reverts on the next evaluation period; trigger-flow demo only — use `inject.sh` for realistic RCA). `--list` enumerates candidate BE/FE alarms. |
| `package-skills.sh` | Zip each `agents/skills/<name>/` folder for upload to AWS DevOps Agent (before/after demo on the managed agent). Reads `agents/skills/manifest.json` and emits **per-space** output: `dist/skills/app-team/` (frontend-triage + report-standards) and `dist/skills/platform/` (the four backend runbooks + report-standards). |
| `upload-skills.sh` | Upload each space's zips from `dist/skills/<space>/` to that space — the two spaces get **different** catalogs (see the manifest). Skills are assets of type `skill`: uploads via `aws devops-agent create-asset` / `update-asset`, then verifies with `list-assets`. Idempotent (matches on `metadata.name`; `assetId` is service-generated). `--dry-run` makes no AWS calls. Manual Operator Web App upload remains documented as a fallback. |
| `register-webhook.sh` | **Required, run once per space** (`--space app-team\|platform`) — without it no alarm can reach an agent. Registers the single account-level `eventChannel` service, associates it to the chosen space, and writes the returned webhook URL + HMAC secret to that space's Secrets Manager entry (`aiops-poc/webhook-credentials` / `aiops-poc/platform-webhook-credentials`), which is where the bridge Lambda reads them from. Idempotent; `--rotate` re-issues the URL and secret. |
| `register-platform-space-mcp.sh` | **PRIMARY space-to-space link.** Register the platform space's remote **MCP** endpoint (`connect.aidevops .../mcp`) as an MCP capability provider in the app-team space (`mcpserversigv4`, tokenless SigV4 + `X-Agent-Space-Id` customHeader). Verifies the endpoint live, allowlists 12 curated investigation/chat tools, checks the trust role; gate-aware (manual steps + exit 2). Supersedes the old `register-capability-providers.sh`. |
| `register-platform-space-agent.sh` | **ALTERNATE (A2A) variant** of the space-to-space link — currently gated with no known exemption process; kept intact as fallback. Registers the platform Agent Space as a remote A2A agent in the app-team space. Automates access-token enable/create/rotate via the control-plane HTTP API, stores the token in Secrets Manager (`aiops-poc/platform-space-a2a-token`), verifies the A2A endpoint, then registers/associates (`remoteagent` service type, bearer auth). Prints pre-filled manual console steps if the account gate fires. |
| `test-delegation.sh` | Validate MCP delegation: fires a test investigation via webhook/CLI, polls for delegation to platform, prints pass/fail. |
| `register-fallback-agents-mcp.sh` | **PRIMARY fallback link.** Register the AgentCore fallback agents (backend_devops_agent, backend_kb_agent — now serving **MCP**) as MCP capability providers in the app-team space (`mcpserversigv4`, service `bedrock-agentcore`, `/aiops-poc/peer` honoring). Verifies each MCP endpoint live (SigV4 `initialize` + `tools/list`) first, detects runtimes still serving A2A (skip + exit 2 with redeploy guidance), allowlists the single `investigate` tool per agent; gate-aware (manual steps + exit 2). |
| `register-fallback-agents.sh` | **ALTERNATE (A2A) variant** of the fallback link — gated with no known exemption process; kept intact as fallback (requires redeploying the runtimes with `protocolConfiguration 'A2A'` + `SERVE_PROTOCOL=A2A`). Registers the AgentCore fallback agents as remote A2A agents in the app-team space (`remoteagentsigv4`, service `bedrock-agentcore`, `/aiops-poc/peer` honoring). Verifies each agent card with SigV4 first; gate-aware (manual steps + exit 2). Supersedes the old `register-remote-agents.sh`. |
| `register-diagnostics-mcp.sh` | **OPTIONAL — descoped from the demo (2026-07).** Register diagnostics_mcp as an MCP capability provider in the platform space (`mcpserversigv4`). The association was removed from the demo path (runtime + service stay; re-running the script restores it). Verifies the MCP endpoint (initialize + tools/list) with SigV4 first and feeds the live tool list into the association; gate-aware (manual steps + exit 2). |
| `test-fallback.sh` | Validate forced-fallback path: deactivate skill → fire webhook → verify report → restore. |
| `destroy-all.sh` | Ordered teardown, including the upstream workshop cleanup procedure. |

## Registration scripts (interconnect links)

See `agent-spaces/README.md → Interconnect runbook (post-exemption)` for
the full ordered runbook, the current account gates, and verification
commands. Short version — run in order once the account is unblocked:

```bash
scripts/register-platform-space-mcp.sh     # link 1: platform space /mcp → app-team (mcpserversigv4) — PRIMARY
scripts/register-fallback-agents-mcp.sh    # link 2: AgentCore agents → app-team (mcpserversigv4) — PRIMARY
# scripts/register-diagnostics-mcp.sh      # link 3 (OPTIONAL, descoped from demo): diagnostics_mcp → platform

# ALTERNATE for link 1 (A2A remote agent, bearer token) — gated, kept as fallback:
# scripts/register-platform-space-agent.sh
# ALTERNATE for link 2 (remote A2A agents, remoteagentsigv4) — gated, kept as
# fallback; needs the runtimes redeployed with protocol A2A + SERVE_PROTOCOL=A2A:
# scripts/register-fallback-agents.sh
```

### `register-platform-space-mcp.sh`

Registers the platform space's remote MCP endpoint
(`https://connect.aidevops.{region}.api.aws/mcp`) as an MCP capability
provider in the app-team space. Verified live (2026-07): the endpoint
answers SigV4 (service `aidevops`) with an `X-Agent-Space-Id` routing
header, and — unlike `remoteagentsigv4` — the `mcpserversigv4` type HAS
`customHeaders`, so the calling agent can inject that header. The link is
therefore tokenless (no access tokens, nothing expires).

```bash
./scripts/register-platform-space-mcp.sh
```

The association allowlists 12 curated investigation/chat tools
(intersected with the live `tools/list`); space-admin and token-admin
tools are deliberately excluded. Post-gate requirement: the
`aiops-poc-remote-agent-registration` role needs `aidevops:*` read/interact
permissions (agents/infra statement `InvokeDevopsAgentRemoteMcp`) — the
script warns if missing.

Gate status (measured live 2026-07-20): plain `mcpserver` (bearer) is
blocked by the general account allowlist (gate 1); `mcpserversigv4`
passes gate 1 but hits the MCP third-party gate (gate 2) **even for the
first-party `connect.aidevops` endpoint**. Unblocking runs through the
third-party MCP access process — the supporting security review lives at
`docs/security/mcp-security-review.md`.

### `register-fallback-agents-mcp.sh` (PRIMARY)

Registers the self-managed fallback agents (backend_devops_agent,
backend_kb_agent — dual-protocol AgentCore runtimes, serving MCP) as MCP
capability providers (`mcpserversigv4`) in the app-team Agent Space. Reads
`/aiops-poc/peer` SSM parameter to determine which agents to register
(`devops` | `kb` | `both`).

```bash
# Register using defaults (profile from config/accounts.json → ops.profile,
# peer from /aiops-poc/peer)
./scripts/register-fallback-agents-mcp.sh

# Override peer selection
./scripts/register-fallback-agents-mcp.sh --peer devops
```

Endpoint per agent: the AgentCore data-plane MCP invocation URL
`https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{urlencoded-runtime-arn}/invocations?qualifier=DEFAULT`
with runtime ARNs from SSM `/aiops-poc/agents/*/runtime-arn`.
Authentication: `mcpserversigv4` with `{region, service:
"bedrock-agentcore", roleArn: aiops-poc-remote-agent-registration}` (trust
role from the agents/infra CDK stack). The association allowlists the
single `investigate` tool each agent exposes. Each endpoint is verified
live first (SigV4 `initialize` + `tools/list`); if a runtime still answers
A2A instead (agents/infra not yet redeployed with the MCP protocol), the
script skips it with explicit redeploy guidance and exits 2.

### `register-fallback-agents.sh` (ALTERNATE, A2A)

The A2A variant of the fallback link, kept intact as fallback (the
`remoteagentsigv4` gate has no known exemption process, unlike the MCP
gate). Registers the fallback agents as remote A2A agents in the app-team
Agent Space; honors `/aiops-poc/peer` the same way. Requires redeploying
the runtimes with `protocolConfiguration 'A2A'` + `SERVE_PROTOCOL=A2A`.

Endpoint per agent (verified live with SigV4): the AgentCore data-plane
agent card URL
`https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{urlencoded-runtime-arn}/invocations/.well-known/agent-card.json`
with runtime ARNs from SSM `/aiops-poc/agents/*/runtime-arn`.
Authentication: `remoteagentsigv4` with `{region, service:
"bedrock-agentcore", roleArn: aiops-poc-remote-agent-registration}` (trust
role from the agents/infra CDK stack).

### `register-diagnostics-mcp.sh` (OPTIONAL, descoped from the demo)

**Descoped 2026-07:** the diagnostics MCP has no demo value — its
platform-space association was removed (the runtime stays deployed and the
service stays registered; re-running this script restores the association).
Future-design note: the right shape is caller-passed resource names rather
than baked-in inventory.

Registers the diagnostics MCP server (AgentCore runtime `diagnostics_mcp`)
as an MCP capability provider (`mcpserversigv4`) in the platform Agent
Space. Verifies the endpoint first (SigV4 `initialize` + `tools/list`) and
passes the live tool list (7 read-only diagnostics tools) to the
association, which requires an explicit tools allowlist.

```bash
./scripts/register-diagnostics-mcp.sh
```

Note: the plain `mcpserver` type (bearer/apiKey/OAuth) is NOT viable for
this runtime — the container has no auth layer and the AgentCore data
plane only accepts SigV4 (no `authorizerConfiguration` is set). The
`mcpserversigv4` type resolves this. The MCP path currently hits its own
account gate ("enable third-party access on your account") distinct from
the general capability-registration allowlist; the script detects both
and prints the applicable guidance.

### `test-fallback.sh`

End-to-end validation of the forced-fallback A2A path:

```bash
# Default: 180s timeout, restores skill after test
./scripts/test-fallback.sh

# Custom timeout, keep skill deactivated for further testing
./scripts/test-fallback.sh --timeout 300 --skip-restore
```

This script asserts on **delegation** — the app-team space choosing to call a
fallback agent — which nothing in the script can force. Its verdicts are
therefore three, not two: `PASS` (exit 0) when a delegated report appears,
`INCONCLUSIVE` (exit 2) when none does inside the window, and `FAIL` (exit 1)
only when its own precondition breaks (the webhook bridge could not be
invoked). An empty window is not evidence that the fallback estate is broken.

To assert on the fallback agents themselves, use
`scripts/smoke-test.sh --custom-only`, which invokes `investigate` over SigV4
and validates the returned report plus its S3 archive.
