# SSM parameter ownership contract

*For anyone replicating this PoC in their own three accounts (BE / FE / OPS)
who did not build it: read this page before a redeploy, and again whenever a
cross-account value looks wrong (a 504 from petsite, an agent that cannot
find a cluster, an FE URL pointing at a BE-internal ALB) — the table below
tells you which account owns the value and whether the sync script is allowed
to overwrite it.*

Every cross-account value in this PoC travels through SSM Parameter Store.
This page is the single source of truth for **who produces each parameter,
who consumes it, in which account(s) it exists, and how (or whether) it is
synced** by `scripts/sync-outputs.sh`. A clean redeploy that respects this
table will come up wired correctly.

Sync behavior legend:

- **synced verbatim** — `sync-outputs.sh` copies the BE (or OPS) value to the
  target account unchanged.
- **FE-owned (skip list)** — the FE stack writes its own value pointing at the
  PrivateLink interface endpoint; `sync-outputs.sh` explicitly skips it so the
  unreachable BE-internal ALB URL never overwrites it.
- **skipped (self-referential)** — exists independently per account; syncing
  would shadow the target account's own value.
- **not synced** — single-account parameter, never copied.

## `/petstore/*` — upstream PetAdoptions service-discovery contract

petsite reads everything under `/petstore` (env `PARAMETER_STORE_PREFIX`) at
startup from **its own account's** Parameter Store. The upstream writes these
in BE; the FE copies come from the FE stack or the sync script.

> Historical note: older upstream revisions used `payforadoptionurl` /
> `sqsqueueurl` / `ecsclustername`, and a single `rdsendpoint`. The current
> pinned upstream uses `paymentapiurl` and `queueurl`, splits the database
> connection details into `rds-writer-endpoint` / `rds-reader-endpoint` /
> `rds-database-name` (alongside `rdssecretarn`), and has **no** cluster-name
> parameter. Docs or scripts referencing the old names are stale: there is no
> `/petstore/rdsendpoint` in either account.
>
> Cluster names, since there is no `/petstore` parameter for them:
>
> - **Backend (BE)** — the upstream services run in the ECS cluster
>   `PetsiteECS-cluster`. Because no SSM parameter publishes it, every
>   consumer (agents, chaos scripts, diagnostics tooling) has to be given the
>   cluster name explicitly.
> - **Frontend (FE)** — petsite runs in its own cluster `aiops-poc-petsite`
>   with service `petsite`, and those names *are* discoverable at runtime via
>   `/aiops-poc/workload/fe-ecs-cluster` and
>   `/aiops-poc/workload/fe-ecs-service`.

| Parameter (`/petstore/…`) | Produced by | Consumed by | Account(s) | Sync behavior |
|---|---|---|---|---|
| `searchapiurl` | BE: upstream CDK (internal ALB URL) / FE: **FrontendStack** (endpoint DNS `:80`, `/api/search?`) | petsite → PetSearch | BE + FE | FE-owned (skip list) |
| `petlistadoptionsurl` | BE: upstream / FE: **FrontendStack** (`:8080`, `/api/adoptionlist/`) | petsite → PetListAdoptions | BE + FE | FE-owned (skip list) |
| `petfoodapiurl` | BE: upstream / FE: **FrontendStack** (`:8081`, `/api/foods`) | petsite → PetFood | BE + FE | FE-owned (skip list) |
| `petfoodcarturl` | BE: upstream / FE: **FrontendStack** (`:8081`, `/api/cart`) | petsite → PetFood cart | BE + FE | FE-owned (skip list) |
| `cleanupadoptionsurl` | BE: upstream / FE: **FrontendStack** (`:8082`, `/api/cleanupadoptions`) | petsite housekeeping → PayForAdoption | BE + FE | FE-owned (skip list) |
| `paymentapiurl` | BE: upstream / FE: **FrontendStack** (`:8082`, `/api/completeadoption`) | petsite checkout → PayForAdoption | BE + FE | FE-owned (skip list) |
| `updateadoptionstatusurl` | BE: upstream CDK (public API Gateway URL); FE placeholder written by FrontendStack | petsite → StatusUpdater API | BE + FE | synced verbatim (public URL, reachable cross-account) |
| `petsiteurl` | BE: upstream (BE CloudFront) / FE: n/a — FE consumers use `/aiops-poc/workload/petsite-url` | upstream canaries (BE) | BE (+ stale FE copies possible) | skipped (self-referential) |
| `petfoodagent-runtime-arn` | BE: upstream CDK (`ENABLE_PET_FOOD_AGENT=true`) | BE: overlay resource policies; FE: petsite Waggle chat | BE + FE | synced verbatim (required for Waggle) |
| `queueurl` | BE: upstream CDK | PayForAdoption; overlay SLO alarm (SQS age); chaos `status-consumer-off`; **diagnostics MCP** — `tool_get_queue_stats` reads it at runtime, and `tool_get_lambda_stats` turns it into the queue ARN to find the consumer function | BE (+ FE copy, unused) | synced verbatim |
| `dynamodbtablename` | BE: upstream CDK | StatusUpdater, PetSearch; overlay; DB seeding; chaos `ddb-throttle`; **diagnostics MCP** — `tool_get_dynamodb_health` reads it at runtime | BE (+ FE copy, unused) | synced verbatim |
| `foods_table_name` | BE: upstream CDK | PetFood; DB seeding (`deploy-upstream.sh`) | BE (+ FE copy, unused) | synced verbatim |
| `carts_table_name` | BE: upstream CDK | PetFood cart | BE (+ FE copy, unused) | synced verbatim |
| `rdssecretarn` | BE: upstream CDK | PayForAdoption, PetListAdoptions; RDS seeding | BE (+ FE copy, unused) | synced verbatim |
| `rds-writer-endpoint` | BE: upstream CDK | PayForAdoption, PetListAdoptions; RDS seeding; **diagnostics MCP** — `tool_get_db_health` reads it at runtime and takes the Aurora identifier from its first DNS label, because no parameter publishes the identifier itself | BE (+ FE copy, unused) | synced verbatim |
| `rds-reader-endpoint` | BE: upstream CDK | read-path consumers | BE (+ FE copy, unused) | synced verbatim |
| `rds-database-name` | BE: upstream CDK (value `adoptions`) | PayForAdoption, PetListAdoptions; RDS seeding | BE (+ FE copy, unused) | synced verbatim |

The upstream also publishes `eventbusname`, `imagescdnurl`, `s3bucketname`,
`rumscriptparameter`, `payforadoptionmetricsurl`, `petfoodmetricsurl` and
`petlistadoptionsmetricsurl` under `/petstore/`. None of them is part of a
cross-account contract this PoC depends on, and none is on the skip list, so
`sync_urls()` copies them to FE verbatim along with everything else it finds
under the prefix — they are listed here only so the set above reads as
complete rather than as a set someone forgot to finish.

The FE-owned skip list lives in `sync_urls()` in
[`scripts/sync-outputs.sh`](../scripts/sync-outputs.sh) — keep it in lockstep
with the parameters `FrontendStack` creates.

### Names this repository resolves at runtime instead of hardcoding

Four backend resources are created by the upstream without an explicit physical
name, so CloudFormation generates one per deployment. **No literal can be
correct in a fresh account**, and none is committed anywhere. Every consumer
resolves them at runtime from the table above:

| Resource | Resolved from | Resolved by |
|---|---|---|
| Adoptions DynamoDB table | `/petstore/dynamodbtablename` | diagnostics MCP `resource_resolver.resolve_adoptions_table`; `chaos/scripts/inject.sh` (`ddb-throttle`) |
| Status-update SQS queue | `/petstore/queueurl` | diagnostics MCP `resolve_status_update_queue`; the overlay's `statusupdate-lag` alarm dimension (deploy time); `inject.sh` / `restore.sh` |
| Aurora cluster identifier | `/petstore/rds-writer-endpoint` — the identifier is the endpoint's first DNS label | diagnostics MCP `resolve_rds_cluster_id` |
| Status-updater Lambda | no parameter publishes it: the queue ARN derived from `/petstore/queueurl`, then the function on its event source mapping | diagnostics MCP `resolve_status_updater_function_name`; `inject.sh` / `restore.sh` (`status-consumer-off`) |

The resolution order in the diagnostics MCP is **caller-supplied argument → SSM
lookup → fail**. There is deliberately no literal fallback: a stale name that
looks plausible turns into a confident wrong answer during an incident (an empty
metric series read as "no traffic"), which is worse than an error. A failure
names the parameter, the account and region it was read from, and the tool
argument that bypasses the lookup. Resolved values are cached for the process
lifetime — a deployment's physical names cannot change while it lives — and
failures are not, so a backend deploy that finishes later is picked up.

Region and credentials for those lookups come from the same contract as every
other AWS call the server makes: `AWS_REGION` and `BE_ACCOUNT_ID`, injected by
`AgentsInfraStack` from `config/accounts.json`, and the
`aiops-backend-domain-read` role, whose policy already allows
`ssm:GetParameter` on `/petstore/*`.

## `/aiops-poc/*` — PoC overlay contract

| Parameter | Produced by | Consumed by | Account(s) | Sync behavior |
|---|---|---|---|---|
| `/aiops-poc/workload/petsite-privatelink-service-name` | BackendOverlayStack (BE) | FrontendStack (`valueFromLookup` at synth — **must be synced before the FE deploy**; `deploy-all.sh` step 3 does this) | BE → FE | synced (dedicated `--section privatelink`) |
| `/aiops-poc/workload/petsite-url` | FrontendStack (FE CloudFront URL) | operators, smoke tests, chaos scripts | FE only | not synced |
| `/aiops-poc/workload/petsite-max-capacity` | FrontendStack default; overwritten by the `ui-no-scale` fault | FrontendStack autoscaling (deploy-time read) | FE only | not synced |
| `/aiops-poc/workload/fe-ecs-cluster`, `/aiops-poc/workload/fe-ecs-service` | FrontendStack (petsite ECS cluster + service names) | chaos scripts (`ui-no-scale` in `inject.sh`/`restore.sh` resolve the FE autoscaling target from these at runtime) | FE only | not synced |
| `/aiops-poc/workload/ecs-cluster`, `pay-for-adoption-url`, `pet-search-url`, `pet-list-adoptions-url`, `status-updater-url`, `ddb-table-name`, `sqs-queue-url` | BackendOverlayStack (re-export of the `/petstore` contract under stable names) | published for agents/tools that want a stable prefix; **nothing reads them today** — the diagnostics MCP resolves from `/petstore/*` directly (see below) and the fallback agents have had no AWS access since the 2026-07 descope | BE only | not synced |
| `/aiops-poc/agent-spaces/app-team/arn`, `/aiops-poc/agent-spaces/platform/arn` | Agent Spaces stack (OPS) | agent-role stacks in FE + BE (association trust) | OPS → FE + BE | synced (`--section arns`) |
| `/aiops-poc/agent-spaces/app-team/operator-app-url` | Agent Spaces stack (OPS) | operators | OPS (copied with the other space params) | synced (`--section arns`) |
| `/aiops-poc/agents/<name>/runtime-arn`, `…/runtime-id` (`<name>` ∈ `backend-devops-agent`, `backend-kb-agent`, `diagnostics-mcp`) | agents/infra (OPS) | `register-fallback-agents-mcp.sh`, `register-diagnostics-mcp.sh` (build the data-plane MCP endpoint); `smoke-test.sh` (custom-estate `investigate` call) | OPS only | not synced |
| `/aiops-poc/kb/knowledge-base-id` | agents/infra (OPS) | backend-kb-agent | OPS only | not synced |
| `/aiops-poc/webhook-bridge-function` | agents/infra (OPS) | webhook registration scripts | OPS only | not synced |
| `/aiops-poc/escalation-topic-arn` | agents/infra (OPS) | operators/scripts (the kb-agent gets the ARN via its `ESCALATION_TOPIC_ARN` env var) | OPS only | not synced |
| `/aiops-poc/peer` | `register-fallback-agents.sh` (OPS) | remote-agent registration and `smoke-test.sh`'s custom-estate check (devops \| kb \| both) | OPS only | not synced |
| `/aiops-poc/skills-enabled` | agents/infra (OPS); toggled by demo scripts | fallback agents' skill loader | OPS only | not synced |
| `/aiops-poc/active-scenario` | `chaos/scripts/inject.sh` / cleared by `restore.sh` | demo bookkeeping only — agents are explicitly forbidden from reading it | BE only | not synced |

The table used to carry a row for
`/aiops-poc/agents/{backend-devops-agent,backend-kb-agent,diagnostics-mcp}-task-role-arn`,
"synced (`--section roles`)" for BE read-role trust tightening. Nothing ever
published those three names, and the two task roles that do exist
(`aiops-poc-agent-task-role`, `aiops-poc-mcp-task-role`) have deterministic
names that `BackendOverlayStack` pins directly in an `ArnEquals` condition on
`aws:PrincipalArn` when it creates `aiops-backend-domain-read`. There is nothing
to sync, so the section and the row are both gone — the trust is tightened at
deploy time without them.

## `config/accounts.json` fields that are not SSM parameters

Nothing in the two tables above is a replicator input. Every value there is
**derived** — produced by a deploy, by the upstream sample, or by a CDK lookup —
and reaches its consumers through SSM or a stack-injected environment variable.
The replicator inputs live in `config/accounts.json`, and the `_doc` block in
`config/accounts.json.template` is their field-level contract: one entry per
field with its description, whether it is required, its default, and the files
that consume it. The four fields below are the ones whose effect lands outside
SSM entirely, so they are easy to look for in the wrong place.

| Field | Consumed by | Notes |
|---|---|---|
| `operator.federationIdentifier` | `agent-spaces/bin/app.ts` (surfaced as the `OperatorFederationIdentifier` stack output) + `deploy-all.sh` step 8 echo | The session name the identity you sign in to the Operator Web App with presents — the last segment of `aws sts get-caller-identity --profile <ops.profile> --query Arn` (`assumed-role/<role>/<session-name>`), which `scripts/setup-config.sh` offers as the prompt default. Wrong when the deploy principal is not the operator (a CI role deploying for a human), and a wrong value fails silently at sign-in. **Not settable via API/CFN** — one-time manual console step per space (Operator Access tab); deploys never overwrite the console value. See [agent-spaces/README.md](../agent-spaces/README.md). |
| `ops.escalationEmail` | `agents/infra/bin/app.ts` → email subscription on the `aiops-poc-escalations` SNS topic | Owning-team email for KB-agent investigation escalations. Real address lives only in the git-ignored `config/accounts.json` (placeholder `REPLACE_WITH_TEAM_EMAIL` in the template). Subscription requires a one-time manual confirmation after deploy. |
| `bedrock.modelId` | `agents/infra` → `MODEL_ID` on the `backend_kb_agent` runtime | Optional; defaults to the cross-region Claude Sonnet inference profile the demo was built on. Profile availability is region- and account-gated, so an account without that profile overrides this field rather than editing the stack. Not published to SSM — the value only exists as runtime environment. |
| `escalation.mode` | `agents/infra` → `ESCALATION_MODE` on the `backend_kb_agent` runtime | Optional, `always` (default) or `auto`. `always` makes every investigation escalate so the email reliably arrives during a demo; `auto` leaves the decision to the agent. Also runtime environment only. |

## Repository hygiene — the live-identifier gate

`scripts/scan-secrets.sh` is the gate that keeps the identifiers above out of
the git history. `scripts/preflight.sh` runs it as check P5 (a warning by
default, a failure under `--strict`). Its scope is every file `git ls-files`
reports, so anything ignored — `config/accounts.json`, `cdk.out/`,
`node_modules/`, the local credentials guide — is out of scope structurally
rather than by pattern list.

It fails on two classes of value:

| Class | What matches | Why it is a leak |
|---|---|---|
| Account identifier | any 12-digit run that is not one of the three canonical placeholders (`111111111111` / `222222222222` / `333333333333`) | names a real account |
| Generated resource name | a physical name carrying a CloudFormation-generated suffix — `<Stack>-<LogicalId><8-hex hash>-<random>`, or the length-capped ELB form `<Abcde>-<Fghij>-<random>` | names one specific deployment's resource; not reproducible, and not caught by the account pattern |

The generated-name rule confirms every candidate before reporting it: the
random suffix must carry an uppercase letter, a digit, and a letter outside the
hex alphabet. That last condition is what keeps UUIDs, git SHAs and asset
digests out, and the first two are what keep ordinary hyphenated names
(`ddb-throttle`, `PetsiteECS-cluster`, `aiops-poc-be-slo-search-latency-p99`,
markdown anchors) out. Documented name *shapes* are unaffected because a shape
written with placeholders has no entropy to match.

### Accepted historical occurrences — `scripts/scan-secrets.baseline`

**Nothing is exempt, and the baseline is empty by design.**

`docs/deployment.md` used to be excluded as a whole file under decision D3,
because its run log quoted the original build's real account IDs and generated
resource names and the argument was that scrubbing them would rewrite the
record. That exclusion was first narrowed to per-value baseline entries — seven
of them, each accepting one exact value in one path. **D3 has now been reversed
outright, on security-standards grounds.** A live account identifier, a
CloudFormation-generated resource name or a reachable endpoint has no business
in a tracked file, and "it is dated historical evidence" is not a standard that
should let anyone grant themselves an exception. The run log's identifiers were
substituted in place with stable placeholders — the same original value always
gets the same placeholder, so the timelines, measurements and cross-references
still read as evidence — and all seven baseline entries were removed.

What that leaves:

- `scripts/scan-secrets.baseline` holds **zero entries**. The file stays because
  the scanner reads it and the test suite covers its parsing, but it is not
  load-bearing: deleting it changes no scan outcome.
- Every line of every tracked file is scanned, `docs/deployment.md` included. A
  live identifier added anywhere fails the gate, with no accepted-value list to
  fall back on.
- A new run log must be written with placeholders from the start. That is the
  fix, not a baseline entry.

**Adding an entry is a last resort**, for a value that genuinely cannot be
placeheld and with a justification a reviewer would defend in a security review.
"The record needs the real value" is exactly the argument that was tried and
rejected. If you still need one:

```bash
scripts/scan-secrets.sh                      # copy the value from the finding
printf '%s' '<value>' | shasum -a 256        # digest it, no trailing newline
# append one line to scripts/scan-secrets.baseline:
#   <path glob> | <digest> | why this value cannot be a placeholder
scripts/scan-secrets.sh                      # must exit 0
```

`sha256sum` and `openssl dgst -sha256` work equally well — the scanner accepts
whichever of the three is installed. The digest is an integrity mechanism, not a
secrecy one: it keeps the baseline from carrying a fresh literal copy of a live
identifier, and it pins an entry to one exact value rather than a shape. The
baseline's own header repeats these steps, so the instructions sit next to the
thing they change.

## Ordering rules that follow from this table

1. **BE overlay before FE stack** — the FE interface endpoint needs
   `/aiops-poc/workload/petsite-privatelink-service-name` synced first.
2. **Sync `--section urls` after any upstream redeploy** — regenerated
   API Gateway URLs (`updateadoptionstatusurl`) and the agent runtime ARN
   (`petfoodagent-runtime-arn`) must reach FE.
3. **Restart petsite after the final sync** (`deploy-all.sh` step 10) —
   petsite caches `/petstore` values at startup.
4. **Never add a FrontendStack-owned parameter without extending the skip
   list** — otherwise the next sync silently reverts it to the unreachable
   BE-internal URL (this is exactly the 504 class of bug fixed in commits
   `2b907eb` and `f78c7d0`).
