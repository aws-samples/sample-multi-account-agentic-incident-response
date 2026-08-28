# AWS DevOps Agent setup — Agent Spaces, delegation, fallback

*For the technical account manager replicating this demo in their own BE / FE /
OPS accounts: this page is the Agent Spaces and connectivity setup you must
reproduce — which spaces exist, which account each is associated with, and how
alarms, delegation, and fallback are wired between them.*

AWS DevOps Agent is the **core of this PoC's agent architecture** (first
responder + platform agent), not an optional add-on. This doc captures the
setup and the connectivity facts (docs last checked 2026-07).

## Agent Spaces

| Agent Space | Created in | Account association | Role |
|---|---|---|---|
| `app-team` | OPS | FE | First responder: picks up every incident, triages the app domain, owns the investigation, posts the RCA |
| `platform` | OPS | BE | Dependent-service agent: investigates the platform on delegation (ECS services, Aurora, DynamoDB, SQS) |

Per-domain spaces are the recommended pattern: scoping keeps investigations
and features like improvement recommendations focused on one team's estate.
A **General Intake** space (fallback for teams without their own space) exists
in the reference pattern; out of PoC scope.

## Connectivity used in this PoC

| Link | Protocol | Mechanism |
|---|---|---|
| Alarm → first responder | Webhook | CloudWatch alarms → SNS → bridge Lambda → space **generic webhook** (HMAC), with a **dual path** — see the alarm fan-out below. Enterprise swap-in: native ServiceNow integration picks up ITSM tickets instead |
| First responder → Platform DevOps Agent | **MCP** | `platform` space's remote MCP endpoint (`https://connect.aidevops.{region}.api.aws/mcp`) registered as a **custom MCP capability provider** in `app-team` — `mcpserversigv4`, tokenless SigV4 (service `aidevops`) + `X-Agent-Space-Id` customHeader for space routing, curated 12-tool allowlist. This is the space-to-space delegation from the reference pattern — mechanics verified live 2026-07 (`scripts/register-platform-space-mcp.sh`); a bearer-token A2A remote-agent variant is kept as the gated alternate (`scripts/register-platform-space-agent.sh`) |
| First responder → self-managed fallback | **MCP** | `backend-devops-agent` and `backend-kb-agent` (Strands agents on AgentCore Runtime) registered in `app-team` as **custom MCP capability providers** — type `mcpserversigv4`, tokenless SigV4 with service `bedrock-agentcore`, each runtime exposing a single `investigate` tool (`scripts/register-fallback-agents-mcp.sh`). Untested alternative: the A2A remote-agent variant (`scripts/register-fallback-agents.sh`) is retained in the repo but has **never been tested** — do not plan a demo around it |
| Platform agent → deterministic tools | MCP | `diagnostics-mcp` registered as a custom MCP capability provider in `platform` (optional but demonstrates outbound MCP to custom tools) |
| Operator (Kiro) → first responder | MCP | Official **AWS DevOps Agent Kiro power** (`DEVOPS_AGENT_TOKEN`, `DEVOPS_AGENT_REGION`) against the `app-team` remote MCP endpoint |

Remote endpoint reference: `https://connect.aidevops.{region}.api.aws` — MCP
at `/mcp`, A2A v1.0 (HTTP+JSON) at `/a2a/*`, agent card at
`/.well-known/agent-card.json`; A2A skills exposed: `investigate` (async,
5–8 min) and `chat`. Auth: Bearer access token (scoped `read`/`operate`,
client type `human`/`agent`, 1–60 day expiry) or SigV4 via
`mcp-proxy-for-aws`.

## Alarm fan-out (reproduce this exactly)

The overlay deploys **15 CloudWatch alarms in 3 tiers**:

| Tier | Prefix | Count |
|---|---|---|
| FE golden signals | `aiops-poc-fe-golden-*` | 3 |
| BE business SLOs | `aiops-poc-be-slo-*` | 6 |
| BE infrastructure | `aiops-poc-be-infra-*` | 6 |

Only **5 of the 15 have alarm actions** and therefore page an agent space:

- the 3 `aiops-poc-fe-golden-*` alarms and `aiops-poc-be-slo-statusupdate-lag`
  page the **app-team** space;
- `aiops-poc-be-infra-payments-tasks` pages the **platform** space — the
  webhook bridge routes on the `aiops-poc-be-infra-*` name prefix.

The other 10 alarms are **actionless**: they exist as context the agents read
during an investigation, not as triggers.

This dual path is why two spaces can investigate the same incident in
parallel: one fault trips alarms in both prefixes, so both spaces get paged
independently.

## Skills

The `agents/skills/` catalog (SKILL.md format) is **split per space** by
`agents/skills/manifest.json`: app-team gets `frontend-triage` +
`untrusted-content-handling` + `report-standards`, platform gets the four
backend runbooks + `untrusted-content-handling` + `report-standards`.
`scripts/package-skills.sh` zips each space's set into
`dist/skills/<space>/` and `scripts/upload-skills.sh` uploads them as assets of
type `skill` (`create-asset` / `update-asset`, verified with `list-assets`);
manual Operator Web App upload is the documented fallback. Skills carry the
symptom→owner routing ("payments declined → payforadoption") and
investigation runbooks. `untrusted-content-handling` is the one skill both
spaces share for a security reason rather than a formatting one: it establishes
that telemetry, alarm text, Knowledge Base passages and peer findings are
evidence to be reported, never instructions to be obeyed, so it has to be in
force wherever content is read. The per-skill **`ACTIVE` / `INACTIVE` status**
gives the before/after demo on the managed agents without redeploying; the
custom fallback agents load the whole catalog from their container image via
their skill loader, so they pick up catalog changes on their next image build
rather than on upload.

## Fallback semantics (the demo moment)

The first responder falls back to the self-managed agents when:

1. the platform investigation returns no confident root cause, or
2. the symptom routes to a domain with no enabled Agent Space.

The fallback is an **MCP tool call** (`investigate`) to a Strands agent on
AgentCore Runtime — still the managed↔custom interop moment over an open
protocol, just MCP rather than A2A, with the custom agent's report also
archived to S3 for side-by-side comparison.

### Delegation status: what the runs show

**Space-to-space delegation is exercised, and the variable that moved it was the
skill catalog.** With skills OFF the app-team space made **0** calls to the
platform-space provider across five recorded `payments-crash` runs — the two-space
behaviour in those recordings came entirely from the dual-path alarm fan-out above,
not from delegation. With the catalog loaded and `agent_types: ["GENERIC"]`, the
app-team responder runs `frontend-triage`'s duplicate check first and then either
opens a platform investigation or joins the one already running. Per-run tool counts
are in [skills-results.md](skills-results.md).

So the thing to demo is no longer "does it delegate at all" but which of the two
delegation shapes a fault produces:

| Fault shape | What the responder does | Recorded on |
|---|---|---|
| No BE alarm pages the platform space for this fault | Duplicate check finds nothing open ⇒ **opens** a platform investigation over the provider's `investigate` tool and adopts its answer | `search-crash` (no infra paging path at all), `ddb-throttle` |
| A BE alarm pages the platform space for the same fault | Duplicate check finds one already open ⇒ **joins** it (`get_task` / `list_journal_records`, typically via a polling subagent) and folds its findings in | `payments-crash` |

`payments-crash` is the only fault where both shapes are reachable, and which one
you get is a **race**, not a setting. `aiops-poc-be-infra-payments-tasks` pages the
platform space under a minute after the FE golden signal pages app-team, so whether
the responder's duplicate check lands before or after that page decides the shape.
Both outcomes are recorded: an earlier skills-ON run checked first, found nothing
open and opened its own platform investigation — leaving **three** investigations
once the BE alarm opened a second platform one a minute later — while the most
recent run found the platform investigation already `PENDING_START` and joined it.
Expect either on stage, and read three investigations as the race resolving the
other way rather than as a duplicate-check failure.

#### Why `create_investigation` never fires (and why that is correct)

The association's 12-tool allowlist includes `create_investigation`, and no
recorded run has ever called it. That is a design consequence, not a broken link,
and it has two independent causes worth stating so nobody goes looking for a bug:

1. **`investigate` is the opener the skill prescribes.** When nothing is open in
   the platform space, `frontend-triage` Step 5 routes the responder to the
   provider's `investigate` tool, which opens the investigation and carries the
   delegation payload in one call. `create_investigation` is the lower-level
   alternative and the skill never sends anyone to it.
2. **Dual-path routing pre-empts delegated creation whenever it wins the race.**
   The webhook bridge sends `aiops-poc-be-infra-*` alarms to the platform space, so
   for `payments-crash` the platform space is paged for the same fault under a
   minute after app-team. When the responder's duplicate check lands after that
   page, a platform investigation already exists and Rule R3 — join, do not
   duplicate — is the correct behaviour: two investigations on one fault split the
   evidence and double the RCA time. Nothing is left for a creation call to do.

Read together: **delegated investigation creation can only be demonstrated
*reliably* on a fault whose backend evidence alarm is actionless** — one of the ten
alarms with no alarm action — because on any fault where both paths overlap the dual
path can get there first, and on `payments-crash` it usually does. `search-crash` is
the clean case: the platform space is never paged for it, so the only route in is the
app-team responder calling the provider, and the creation half of the hop is
unambiguous. Do not read the absence of `create_investigation` from a
`payments-crash` journal as a delegation failure; check for the read tools and the
join instead.

Whichever shape you demo, **check the traces** — confirm the delegation calls in the
investigation's utilization record rather than inferring delegation from two reports
existing, because the dual path produces two reports on its own.

#### The bounded wait is the part to watch

`frontend-triage` Step 8 requires the responder to poll the delegated task's
`status` to `COMPLETED` or `FAILED` before writing its root cause. This has already
failed twice in different ways — once by closing ahead of the delegation and filing
a cross-account gap the platform report had already answered, once by a **polling
subagent** deciding the journal held complete findings and reporting back while the
task was still `IN_PROGRESS`, closing about ten seconds early. The skill now keys the
exit on the `status` field only, binds the rule to whoever does the polling, and
requires the responder to re-check `status` itself before writing the root cause. On
a live run, compare the two investigations' completion timestamps: app-team should
close **after** the platform space, not before.

## Caveats to verify at build time

- Remote A2A agents are **incident-investigation-only** today.
- Space-to-space MCP registration (a DevOps Agent remote MCP endpoint as
  another space's capability provider) — verified live (2026-07): the
  `/mcp` endpoint answers SigV4 (service `aidevops`) with an
  `X-Agent-Space-Id` routing header, and `mcpserversigv4` supports
  `customHeaders`, so the link is tokenless. Registration currently hits
  the MCP third-party gate **even for this first-party endpoint**; unblock
  via the third-party MCP access process
  (`docs/security/mcp-security-review.md`). Tool exposure is constrained
  by the association's explicit allowlist (12 curated investigation/chat
  tools; space-admin/token-admin tools excluded).
- Pricing is consumption-based with no built-in cap — set budget alarms.
- The service moves fast (custom agents and MCP/A2A endpoints shipped
  June 2026); re-check docs before the build tasks.
