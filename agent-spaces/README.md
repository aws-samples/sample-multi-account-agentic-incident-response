# agent-spaces — AWS DevOps Agent setup (Account OPS)

*For the technical account manager replicating this demo in their own BE / FE /
OPS accounts: read this to stand up both Agent Spaces, wire the two webhooks and
the MCP capability providers, and know which single step still has to be done by
hand in the console.*

CDK stack for the two AWS DevOps Agent **Agent Spaces** that form the managed
side of the architecture, deployed to the **OPS** account in **`us-east-1`**.
Account id, region and profile all come from `config/accounts.json → ops`
(git-ignored; copy `config/accounts.json.template` and fill it in) — nothing
here is hardcoded and no account id needs to be typed. Every `scripts/…` command
below resolves the profile and region from that file itself, so it is
copy-pasteable as written; the raw `npx cdk` / `aws` examples show
`--profile <ops.profile>`, meaning substitute your own OPS profile name there.

Modeled on the
[aws-samples/sample-aws-devops-agent-cdk](https://github.com/aws-samples/sample-aws-devops-agent-cdk)
reference pattern.

> **Deploy order.** This stack is late in the sequence: BE upstream → BE overlay
> → FE workload → `agents/infra` → **`agent-spaces/`** → the non-CloudFormation
> script steps (webhooks, capability providers, skills) → smoke test. The full
> order, prerequisites and the resumable `scripts/deploy-all.sh` wrapper are in
> [docs/deployment.md](../docs/deployment.md#deployment-order).

## Architecture

| Space | Account association | Role |
|---|---|---|
| `aiops-poc-app-team` | FE (your frontend account) | First responder: owns every incident, triages the app domain, posts the RCA. Paged by the 3 `aiops-poc-fe-golden-*` alarms and `aiops-poc-be-slo-statusupdate-lag` |
| `aiops-poc-platform` | BE (your backend account) | The live-telemetry investigator for the backend domain. Paged directly by `aiops-poc-be-infra-payments-tasks` (the bridge routes on the `aiops-poc-be-infra-*` prefix), and reachable from `app-team` as an **MCP** capability provider — see [Space-to-space delegation](#space-to-space-delegation-app-team--platform) |

> **Honest note on delegation.** Across the 5 recorded `payments-crash` runs the
> app-team space made **0** delegation calls into the platform space. The
> two-space behaviour you see in those recordings comes from the **dual-path
> alarm fan-out** (both spaces paged independently), not from a hand-off. The
> space-to-space MCP provider is registered and associated; if you want to demo
> delegation itself, force it (prompt app-team to consult the platform provider,
> or remove the `aiops-poc-be-infra-payments-tasks` alarm action so the platform
> space is only reachable via delegation) and then check the investigation
> journal to confirm the call happened.

## Two-phase deploy

The stack uses a **context flag** (`ENABLE_ASSOCIATIONS`) to support a
two-phase deployment because the source associations require the agent roles in
the FE/BE accounts to exist first (`FrontendAgentRoleStack` in FE,
`BackendAgentRoleStack` in BE — see [Role model](#role-model)). Those role
stacks in turn need the space ARNs from phase 1, so the order is
phase 1 → `sync-outputs.sh` → role stacks → phase 2.
`scripts/deploy-all.sh` runs all of it for you.

> **The context default in `cdk.json` is `ENABLE_ASSOCIATIONS: "true"` — the
> steady state.** Once phase 2 has run, the associations exist in the deployed
> stack, so `true` is what makes a plain `cdk deploy`/`cdk diff` match reality
> (`cdk diff` reports no differences). A default of `false` would instead make
> every subsequent deploy **delete** both associations, so do not flip it back:
> the flag is a phase-1 opt-out, not a steady-state setting. Phase 1 of a fresh
> deployment passes `-c ENABLE_ASSOCIATIONS=false` explicitly (as
> `scripts/deploy-all.sh` step 5 does).

### Phase 1 — Spaces + roles (no external dependencies)

```bash
cd agent-spaces
npx cdk deploy -c ENABLE_ASSOCIATIONS=false --profile <ops.profile>
```

Creates:
- Both Agent Spaces (`AWS::DevOpsAgent::AgentSpace`)
- OPS monitor role (operator web app role) — see
  [Role model](#role-model) below
- Operator app (IAM auth) for each space
- SSM parameters exporting space ARNs:
  - `/aiops-poc/agent-spaces/app-team/arn`
  - `/aiops-poc/agent-spaces/platform/arn`
  - `/aiops-poc/agent-spaces/app-team/operator-app-url`

After phase 1, run `scripts/sync-outputs.sh` to propagate the space ARNs to the
FE/BE accounts, then deploy the two agent-role stacks
(`FrontendAgentRoleStack`, `BackendAgentRoleStack`).

### Phase 2 — Source associations (after agent roles exist)

```bash
npx cdk deploy -c ENABLE_ASSOCIATIONS=true --profile <ops.profile>
```

(`-c ENABLE_ASSOCIATIONS=true` is redundant with the `cdk.json` default; it is
spelled out so the phase-2 step reads the same whatever the default is.)

Creates:
- `AWS::DevOpsAgent::Association` — app-team → FE account (DevOpsAgentRole-AppTeam)
- `AWS::DevOpsAgent::Association` — platform → BE account (DevOpsAgentRole-Platform)

Allow a few minutes for IAM propagation before the associations become active.

## Role model

All roles follow the DevOps Agent console guidance (verified against a
console-created reference space and its auto-created
`DevOpsAgentRole-WebappAdmin-*` role).

### Cloud source roles (FE + BE)

`DevOpsAgentRole-AppTeam` (FE, `FrontendAgentRoleStack`) and
`DevOpsAgentRole-Platform` (BE, `BackendAgentRoleStack`):

- **Trust**: principal `aidevops.amazonaws.com`, action `sts:AssumeRole`,
  condition `StringEquals` on `aws:SourceAccount` (the OPS account) **and**
  `aws:SourceArn` (the exact agent space ARN, read from
  `/aiops-poc/agent-spaces/*/arn` synced SSM).
- **Managed policy**: `AIDevOpsAgentAccessPolicy` (AWS managed — contains
  every read permission the agent needs, including Resource Explorer; no
  hand-rolled read policies).
- **Inline policy** (verbatim console guidance): `iam:CreateServiceLinkedRole`
  on `arn:aws:iam::<account>:role/aws-service-role/resource-explorer-2.amazonaws.com/AWSServiceRoleForResourceExplorer`.

### Operator web app role (OPS)

`aiops-poc-devops-agent-monitor` — a single role serving both spaces:

- **Trust**: `aidevops.amazonaws.com` with `sts:AssumeRole` **and**
  `sts:TagSession`, scoped to the OPS account and `agentspace/*`.
- **Managed policies**: `AIDevOpsOperatorAppAccessPolicy` (the operator web
  app policy — scopes aidevops actions by the `AgentSpaceId` session tag,
  which is why `TagSession` is required) plus `AIDevOpsAgentAccessPolicy`.
- **Inline policy**: a tag-independent aidevops read/interact set scoped
  explicitly to the two space ARNs (safety net; this fixed the original
  "not authorized to perform: aidevops:ListBacklogTasks" web app error).

### Actions role — intentionally not configured

The Capabilities tab shows "Actions role not configured" for both spaces.
This is deliberate: the PoC is investigation-only, so agents get read access
and no write/remediation actions.

## Manual step: Operator Web App federation identifier

The federation identifier (the identity operators federate onto the operator
role with) **cannot be set via the API or CloudFormation** — verified against
the service model (`EnableOperatorApp`/`GetOperatorApp` only carry
`operatorAppRoleArn`) and `AWS::DevOpsAgent::AgentSpace`. Set it once per
space in the console:

1. DevOps Agent console → the space → **Operator Access** tab
2. Enter the federation identifier from
   `config/accounts.json → operator.federationIdentifier`
3. Repeat for the **second** space — this is per-space, not per-account

**What that value is, and how to find it.** It is *the session name the identity
you will sign in to the web app with presents* — an SSO session name is one
example of such a session name, not the definition. Where you deploy with the
same federated identity you open the web app with, read it off the credentials
you already have:

```bash
aws sts get-caller-identity --profile <ops.profile> --query Arn --output text
# arn:aws:sts::<ops-account>:assumed-role/<role>/<THIS-IS-THE-VALUE>
```

The last slash-delimited segment is the value, and `scripts/setup-config.sh`
offers exactly that as the prompt default. **Caveat:** if the deploy runs under a
CI or automation role while a human operates the web app under their own
identity, the deploy profile's session name is the **wrong** value — use the
human identity's session name. A wrong value is accepted by config and by the
console alike; the only symptom is that sign-in silently does not work.

Deploys never touch this setting, so a value set manually in the console is
preserved across redeploys. `deploy-all.sh` echoes a reminder, and the stack
surfaces the configured value as the `OperatorFederationIdentifier` output
(present only when `operator.federationIdentifier` is set in config).

## Automated steps (formerly manual)

### Generic webhooks (BOTH spaces) — AUTOMATED

Webhook creation is exposed via the `aws devops-agent` API
(`register-service` with an `eventChannel` service + `associate-service`,
which returns the `GenericWebhook` URL and HMAC secret). The whole flow is
scripted, and you need to run it **twice — once per space**:

```bash
scripts/register-webhook.sh --space app-team
scripts/register-webhook.sh --space platform
```

The script:
1. Registers an `eventChannel` service named `aiops-poc-incidents`
   (reused if it already exists — one service fans out to both spaces via
   per-space associations)
2. Associates it to the chosen space — the response contains the
   webhook URL and HMAC signing secret
3. Writes both to Secrets Manager — `aiops-poc/webhook-credentials`
   (app-team) or `aiops-poc/platform-webhook-credentials` (platform), each
   as JSON `{"webhook_url": "...", "hmac_secret": "..."}`, exactly the keys
   the webhook bridge Lambda reads

The webhook bridge Lambda reads from Secrets Manager at runtime — no
redeploy is needed after setting or rotating the credentials. To rotate,
run with `--rotate` (disassociates and re-creates the webhook, issuing a
new URL + secret).

Verify end-to-end with `scripts/smoke-test.sh --managed-only` — it fires a
synthetic alarm through the bridge and confirms the resulting investigation
via `aws devops-agent list-backlog-tasks` (taskType `INVESTIGATION`).

> **Both webhooks are required — this is the dual path.** The bridge routes
> alarms named `aiops-poc-be-infra-*` to the **platform** webhook and
> everything else to the **app-team** webhook. Register only app-team and
> `aiops-poc-be-infra-payments-tasks` has nowhere to go, which removes half of
> the `payments-crash` (B3) story. Alarm inventory and routing:
> [docs/deployment.md](../docs/deployment.md#alarm-inventory).

> **Fallback:** `./set-webhook-secret.sh` still exists for manually entering
> credentials from the Operator Web App if the API path is unavailable.

### Access tokens — AUTOMATED (control-plane HTTP API, only needed for the A2A alternate)

Token creation **is** exposed via the DevOps Agent control-plane HTTP API
(`https://cp.aidevops.{region}.api.aws`, SigV4 service `aidevops`) even
though the AWS CLI has no commands for it (this corrects earlier guidance
here that said tokens were web-app-only). Verified operations:

```
PATCH /v1/agentspaces/{id}                              {"accessTokensEnabled": true}
POST  /v1/agentspaces/{id}/access-tokens                {"tokenName": "...",
      "scopes": ["agent:operate"|"agent:read"],
      "clientType": "AGENT"|"HUMAN", "expirationDays": 1-60}
      → response contains "accessToken" (shown exactly once)
GET   /v1/agentspaces/{id}/access-tokens
POST  /v1/agentspaces/{id}/access-tokens/{tid}/rotate   → "newAccessToken"
```

`scripts/register-platform-space-agent.sh` (the untested A2A variant of
the space-to-space link, see below) uses these to mint and store the
platform space's agent-type token (Secrets Manager:
`aiops-poc/platform-space-a2a-token`). **The deployed MCP link is tokenless
and needs none of this** — you can skip this section entirely unless you are
experimenting with the A2A variant.

### Space-to-space delegation (app-team → platform)

The deployed space-to-space link registers the platform space's remote
**MCP** endpoint as an MCP capability provider in app-team. Mechanism,
verified live:

- The platform space's remote MCP endpoint is the shared regional server
  `https://connect.aidevops.{region}.api.aws/mcp` (stateless streamable
  HTTP, JSON-RPC: `initialize`, `tools/list`, ...).
- **Space routing — both auth modes verified live:** a space-bound Bearer
  token routes implicitly (24 tools with `agent:operate` scope); SigV4
  (service `aidevops`) with an `X-Agent-Space-Id` header routes explicitly
  (34 tools with admin credentials).
- **Unlike `remoteagentsigv4`, the `mcpserversigv4` type HAS
  `customHeaders`** in its `authorizationConfig` (verified in the
  2026-01-01 service model) — so the calling DevOps Agent CAN inject
  `X-Agent-Space-Id`, making SigV4 viable for space-to-space MCP. The link
  is therefore **tokenless**: no access tokens, no 60-day expiry, no
  rotation.
- Registration: `register-service --service mcpserversigv4` with
  `authorizationConfig {region, service: "aidevops", roleArn:
  aiops-poc-remote-agent-registration, customHeaders:
  {"X-Agent-Space-Id": <platform-space-id>}}`; the association carries a
  curated 12-tool investigation/chat allowlist (space-admin and
  token-admin tools excluded).

The whole flow is scripted and idempotent:

```bash
scripts/register-platform-space-mcp.sh
```

> **Expect an account gate on a fresh account.** Two gates exist, and which
> one you hit depends on the registration type: plain `mcpserver` (bearer) is
> blocked by the general capability-registration allowlist (AccessDenied) —
> the same gate that blocks `remoteagent`. `mcpserversigv4` passes that one
> but can hit the **MCP third-party access** gate (ValidationException) **even
> for the first-party `connect.aidevops` endpoint** — the internal MCP
> allowlist does not exempt DevOps Agent's own remote MCP server. Unblocking
> runs through the third-party MCP access process (security review:
> [docs/security/mcp-security-review.md](../docs/security/mcp-security-review.md)),
> which is an account setting in the DevOps Agent console, not an API call.
> The script automates everything up to the gate — live endpoint verification
> (SigV4 + routing header), curated tool allowlist, trust-role check — and
> prints pre-filled manual console steps when the gate fires. On this
> deployment the provider ended up registered and associated to the app-team
> space, so it is reachable; see the delegation note at the top of this page
> for what the recorded runs actually did with it.

> **Post-gate requirement:** the `aiops-poc-remote-agent-registration`
> role needs `aidevops` read/interact permissions (agents/infra statement
> `InvokeDevopsAgentRemoteMcp`) — redeploy `agents/infra` if the script's
> Step 2 warns.

### Space-to-space delegation — A2A remote agent (untested alternate, do not demo)

The A2A variant of the same link is kept in the repo for contrast only
(`scripts/register-platform-space-agent.sh`). **It has never been run to
completion**: its `remoteagent` registration is blocked by the
account-allowlist gate with **no findable authorization/exemption process**,
while the MCP gate has a known unblock path; it also requires space-bound
bearer tokens (60-day expiry + rotation). Do not present A2A as the deployed
path. Mechanism, as far as it was verified (endpoint reads only):

- The platform space's A2A endpoint is the shared regional remote server
  `https://connect.aidevops.{region}.api.aws` — agent card at
  `/.well-known/agent-card.json`, A2A v1.0 (HTTP+JSON) at `/a2a/*`
  (e.g. `POST /a2a/message:send`, header `A2A-Version: 1.0`).
- **Space routing:** a Bearer access token is bound to exactly one space,
  so bearer auth routes to the platform space with no extra configuration.
  **SigV4 does not work for the space-to-space A2A variant**: with SigV4
  the shared endpoint requires an `X-Agent-Space-Id` header, and the
  `remoteagentsigv4` registration type has no `customHeaders` field
  (verified against the service model), so the calling DevOps Agent could
  never inject it. Bearer is the only viable auth for the A2A link.
  (This is exactly the asymmetry that favors the MCP variant:
  `mcpserversigv4` DOES have `customHeaders`.)
- Registration: `aws devops-agent register-service --service remoteagent`
  (bearerToken auth config) + `associate-service` to the app-team space
  with `--configuration '{"remoteagent": {}}'`.

The whole flow is scripted and idempotent:

```bash
scripts/register-platform-space-agent.sh
```

> **Account gate:** `register-service` for **both** `remoteagent` and
> `remoteagentsigv4` failed with the same gate as `mcpserver`:
>
> ```
> AccessDeniedException: Account <OPS_ACCOUNT_ID> is not authorized.
> Only external accounts and exempted accounts are allowed at this time.
> ```
>
> (Confirmed via the CLI and by calling the control-plane
> `POST /v1/register/remoteagent` directly.) The script automates
> everything up to the gate — token enable/create/rotate, secret storage,
> live A2A endpoint verification against the platform space — and prints
> pre-filled manual console steps (Capability Providers → Remote Agent →
> Register, bearer token from the secret) when the gate fires. The console
> calls the same API, so an account exemption is likely required either
> way.

> **Status:** MCP is the implemented and deployed link (tokenless SigV4). This
> A2A variant is **unvalidated end to end** — treat any demo of it as
> exploratory work, not a reproducible path.

## Interconnect runbook

The interconnect links are fully scripted, idempotent, and **gate-aware**: each
script verifies its endpoint (read-only) first, then attempts registration; if
an account gate fires it prints pre-filled manual console steps and exits 2.
Two gates can block `register-service`:

1. **Capability-registration allowlist** (`remoteagent`,
   `remoteagentsigv4`, plain `mcpserver`):
   `AccessDeniedException: Account <OPS_ACCOUNT_ID> is not authorized.
   Only external accounts and exempted accounts are allowed at this time.`
   — needs an account exemption, and no self-service process for it was
   found. This is why the A2A registrations were never completed.
2. **MCP third-party access** (`mcpserversigv4`): `ValidationException:
   This account can only register internally allowlisted MCP servers. To
   register other MCP servers, enable third-party access on your
   account.` — "third-party access" is an account setting not exposed in
   the CLI/API (verified against the service model); enable it via the
   DevOps Agent console settings or the third-party MCP access process
   (security review:
   [docs/security/mcp-security-review.md](../docs/security/mcp-security-review.md)).
   This gate fires **even for the first-party `connect.aidevops` remote MCP
   endpoint**, so the internal allowlist does not exempt DevOps Agent's own
   endpoint.

Run the three MCP registrations in this order (each takes its profile and region
from `config/accounts.json → ops`, so there is nothing to pass):

```bash
# Link 1 — platform space /mcp → app-team, MCP capability provider
#   (mcpserversigv4, SigV4 service `aidevops`, tokenless, with the
#   X-Agent-Space-Id customHeader; curated 12-tool investigation/chat
#   allowlist).
scripts/register-platform-space-mcp.sh

# Link 2 — AgentCore fallback agents → app-team, MCP capability providers
#   (mcpserversigv4, SigV4 service `bedrock-agentcore`, trust role
#   aiops-poc-remote-agent-registration; single `investigate` tool per
#   agent). Honors /aiops-poc/peer. Verifies each MCP endpoint live and
#   detects runtimes still serving A2A.
scripts/register-fallback-agents-mcp.sh

# Link 3 (optional) — diagnostics_mcp → platform, MCP capability provider
#   (mcpserversigv4, same SigV4 config; association carries the live
#   tools/list — 7 read-only diagnostic tools). Descoped from the main
#   narrative; skip unless you want to demo custom MCP tools.
scripts/register-diagnostics-mcp.sh
```

The A2A equivalents of links 1 and 2
(`scripts/register-platform-space-agent.sh`,
`scripts/register-fallback-agents.sh`) are **untested** and blocked by gate 1 —
they are not part of the replication path.

Verification after each link:

```bash
# Link 1: delegation end-to-end (app-team chat → platform investigation).
#   Both scripts take their profile and region from config/accounts.json
#   (ops.profile / ops.region); the flags below are optional overrides.
scripts/test-delegation.sh

# Link 2: forced-fallback path (deactivate skill → webhook → report).
scripts/test-fallback.sh

# Link 3: in the platform space Operator Web App, confirm
#   aiops-poc-diagnostics-mcp shows Connected with 7 tools, then ask the
#   space to check backend service health (should call
#   tool_get_service_health).

# Registration state at any time (space ids come from SSM — never typed):
aws devops-agent list-services --profile <ops.profile> --region us-east-1
SPACE_ARN=$(aws ssm get-parameter --name /aiops-poc/agent-spaces/app-team/arn \
  --query 'Parameter.Value' --output text --profile <ops.profile> --region us-east-1)
aws devops-agent list-associations --agent-space-id "${SPACE_ARN##*/}" \
  --profile <ops.profile> --region us-east-1
```

Endpoint conventions the scripts rely on (verified live with SigV4):

- AgentCore MCP endpoint (fallback agents + diagnostics_mcp — all three
  runtimes now serve MCP):
  `POST https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{urlencoded-runtime-arn}/invocations?qualifier=DEFAULT`
- AgentCore A2A agent card (the untested alternate serving mode):
  `GET https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{urlencoded-runtime-arn}/invocations/.well-known/agent-card.json`
- Runtime ARNs come from SSM `/aiops-poc/agents/*/runtime-arn` — never typed.

Skills upload is scripted (not a manual step):

```bash
# Per-space catalogs — agents/skills/manifest.json declares the split:
#   app-team: frontend-triage + report-standards
#   platform: the four backend runbooks + report-standards
scripts/package-skills.sh                       # writes dist/skills/<space>/
scripts/upload-skills.sh   # profile + region from config/accounts.json → ops.*
```

`upload-skills.sh` uploads each space's zips as assets of type `skill`
(`create-asset` / `update-asset`) and verifies with `list-assets`; it is
idempotent, matching on `metadata.name` because `assetId` is service-generated.
Upload by hand in the Operator Web App (Knowledge → Skills → zip upload) only as
a fallback — and then upload only the zips under that space's directory, since
the catalogs differ. Capture a skills-OFF baseline before uploading (or flip
`metadata.status` to `INACTIVE` in the console) if you want a genuine
before/after.

Still manual besides the gates:

- **Operator Web App federation identifier**, once per space (see above).
- **Escalation email confirmation** — the `aiops-poc-escalations` SNS topic
  sends a one-time subscription confirmation to `ops.escalationEmail`.

## Development

```bash
npm install
npm run build   # compile TypeScript
npm test        # run CDK assertions
npx cdk synth   # synthesize CloudFormation template
npx cdk diff    # preview changes
```

## Stack outputs

| Output | Export name | Description |
|---|---|---|
| AppTeamSpaceArn | AiopsAppTeamSpaceArn | ARN of the app-team space |
| PlatformSpaceArn | AiopsPlatformSpaceArn | ARN of the platform space |
| AppTeamSpaceId | AiopsAppTeamSpaceId | ID of the app-team space |
| PlatformSpaceId | AiopsPlatformSpaceId | ID of the platform space |
| OpsMonitorRoleArn | AiopsOpsMonitorRoleArn | OPS monitor role ARN |
| OperatorFederationIdentifier | — | Reminder value for the manual console step; only emitted when `operator.federationIdentifier` is set in config |

Space ARNs and ids are also published to SSM
(`/aiops-poc/agent-spaces/{app-team,platform}/arn`), which is where every script
and command in this repo reads them from — you should never need to copy an id
by hand.

## Related docs

- [docs/aws-devops-agent-integration.md](../docs/aws-devops-agent-integration.md) — endpoint facts, auth, delegation patterns
- [docs/deployment.md](../docs/deployment.md) — full deploy order across all accounts
