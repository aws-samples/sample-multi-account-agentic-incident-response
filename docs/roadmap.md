# Roadmap

The [README](../README.md) covers what this PoC proves. This page is the other
half: the paths that are designed and wired but not yet exercised, the faults
that need something the deployed upstream does not give us, and the
measurements that would firm up the results. Each item says what exists today
and what completing it would take, so anyone picking the project up knows where
the next increment starts.

## A2A links — available, not yet exercised

Both agent-to-agent links on this deployment run over **MCP**, and A2A is
available on the same containers and endpoints rather than absent:

- Both self-managed Strands agents are dual-protocol images. They serve A2A on
  **:9000** and MCP on **:8000/`mcp`**, switched by the `SERVE_PROTOCOL`
  environment variable, so no rebuild is needed to flip a runtime over.
- The DevOps Agent remote endpoint speaks both: MCP at `/mcp` and A2A v1.0
  (HTTP+JSON) at `/a2a/*`, with the agent card at
  `/.well-known/agent-card.json` and `investigate` / `chat` exposed as A2A
  skills.
- The registrations exist as annotated alternates —
  `scripts/register-platform-space-agent.sh` for the space-to-space link and
  `scripts/register-fallback-agents.sh` for the fallback agents.

MCP is the exercised path for one reason: its account gate has a **documented
unblock process** (the third-party MCP access review, see
[security/mcp-security-review.md](security/mcp-security-review.md)), while the
A2A remote-agent registration gate has no known one. Exercising A2A would take
the account unblock for remote A2A agent registration; a bearer access token
(scoped `read`/`operate`, 1–60 day expiry) because A2A registration is
token-based rather than tokenless SigV4, which also brings token rotation into
the demo's operational surface; re-registering either link with the scripts
above; and one recorded run per link to compare against the MCP numbers in
[skills-results.md](skills-results.md). One product constraint to plan around:
remote A2A agents are **incident-investigation-only** today.

## EKS variant

The delegation pattern is identical on EKS. The platform space would investigate
through kubectl / the EKS MCP server instead of the ECS APIs, and nothing else
in the design changes — the alarm tiers, the webhook routing, the skill catalog
and the first-responder flow are all platform-agnostic.

The estate is already there: the upstream sample deploys **its own petsite copy
on the EKS cluster `PetsiteEKS-cluster`** in the backend account, which keeps
running and sits unused by this demo (the construct that would have disabled it
was omitted — it is a Kubernetes Deployment, not an ECS service, so scaling it
from CDK was out of scope). Making it a variant means pointing the platform
space at that cluster and adding an EKS-shaped fault, not standing up new
infrastructure.

## Scenarios not yet runnable

Four faults are designed and already coded into `chaos/scripts/inject.sh`, which
fails fast with a message pointing at the docs rather than half-injecting. All
four are blocked on upstream behaviour the deployed container images do not have
— none of them needs a change to the detection or agent wiring. Definitions:
[scenarios.md](scenarios.md#future-enhancements).

**`checkout-degraded` and `db-overload` (B1), `payments-error` (B3)** need
PetAdoptions' built-in chaos, degradation and DB-simulator HTTP endpoints:
`POST /degradation/*` and `POST /chaos/*` on payforadoption, `POST /simulate/*`
on petlistadoption. Those endpoints are **not present in the images this
deployment runs** — an in-VPC probe returned HTTP 404, and petlistadoption's
OpenAPI lists only `/api/adoptionlist/`, `/health/status` and `/metrics`.
Enabling them means forking and rebuilding two upstream microservices, which the
project's unforked-upstream fidelity rule keeps out of scope, so the path
forward is a chaos-enabled upstream image. The contrasts waiting behind them:
**app-delay vs DB-contention** for B1 (both make checkout slow with nothing
erroring, but only `db-overload` shows Aurora lock waits, so the agent has to
look one level further down) and **error-vs-crash** for `payments-error` (a
service that stays up and returns errors keeps emitting traces and error
metrics, where the active `payments-crash` goes silent — and a ratio-based error
alarm can go blind during a total outage because it loses its denominator).

**`status-consumer-off` (B2)** is blocked one layer up, because both halves are
built and verified. The fault injects cleanly and reversibly by disabling the
SQS event source mapping on the status-updater Lambda, resolved by queue ARN.
The detector is live: `aiops-poc-be-slo-statusupdate-lag` derives its queue
dimension from the SSM `/petstore/queueurl` value at deploy time (it previously
hardcoded the upstream logical queue name and matched no metric), it resolves to
the live queue, and its SNS action is wired. What is missing is upstream
traffic — the deployed upstream's adoption path never publishes status messages,
so the queue never ages and the alarm can never fire.
`chaos/scripts/trigger-alarm.sh` can still force that alarm to rehearse the
chain. The teaching point waiting behind it is **sync-vs-async**: checkout
succeeds and feels fast while an adopted pet keeps its old status, so the
queue-age SLO is the only detector and an agent that assumes "backend problem ⇒
checkout is affected" is wrong here.

## `ui-no-scale` (B5) — finish the local-only control case

What is proven: the fault pins petsite's ECS autoscaling ceiling in the frontend
account, it genuinely saturates petsite under real load, the golden alarms fire,
and the alarm → webhook → investigation chain runs end to end. It is also the
only fault that targets the frontend account.

What a full diagnosis still needs: a single load-driven run carried all the way
through to a **local-only** root cause — autoscaling pinned, tasks healthy but
saturated, no delegation — so that the discriminating behaviour is positively
demonstrated rather than merely consistent with what was observed. Practically
that means **two concurrent load generators** (one leaves saturation
intermittent), a quiet window before T0, and an investigation created by the
real fault rather than by a forced alarm, which is why B5 is currently excluded
from the skills before/after ([why](skills-results.md#excluded-scenarios)).
Completing it gives the demo its negative control: evidence that the agents
discriminate instead of reflexively escalating everything to the backend.

## Delegated investigation creation

The platform-space association's 12-tool allowlist includes
`create_investigation`, and no recorded run has called it. That is a design
consequence rather than a broken link, for two independent reasons: the
`frontend-triage` skill routes the responder to the provider's `investigate`
tool, which opens the investigation and carries the delegation payload in one
call; and on faults where the dual path overlaps, the platform space is usually
already paged for the same fault, so the skill's join-don't-duplicate rule
correctly applies and there is nothing left for a creation call to do.

Demonstrating delegated creation *deliberately* therefore needs a fault whose
backend evidence alarm is **actionless** — one of the ten alarms with no alarm
action — because on any fault where both paths overlap the dual path can win the
race. `search-crash` is the clean case: the platform space is never paged for
it, so the only route in is the responder calling the provider. Full reasoning:
[aws-devops-agent-integration.md](aws-devops-agent-integration.md#why-create_investigation-never-fires-and-why-that-is-correct).

## Measurement depth

The skills before/after in [skills-results.md](skills-results.md) is **one run
per scenario** (two for `ddb-throttle`), not a distribution, and the numbers
have visible run-to-run spread — the same fault with the same catalog came in at
11 min 57 s and 14 min 01 s. Three things more repeats would settle:

- **Variance on time to RCA.** Two ON runs of one scenario cannot separate a
  skills effect from ordinary run-to-run noise; the effect sizes are large
  enough that the direction is not in doubt, but the magnitudes are single
  observations.
- **Cross-space call counts are floors, not exact counts.** Where a polling
  subagent does the reading, its calls are not itemized in the parent
  investigation's utilization record, which is why one scenario shows 3 calls
  and another 31 for the same single delegation. The claim that survives any
  number of repeats is 0 versus non-zero.
- **The `payments-crash` OFF baseline is the most recent run only.** Four
  earlier runs used different alarm and canary wiring (5-minute canary,
  actionable backend SLO alarms, single-path fan-out) and are not comparable, so
  they are excluded.

## The bounded wait on a live run

`frontend-triage` Step 8 requires the responder to poll the delegated task's
`status` to `COMPLETED` or `FAILED` before writing its root cause. That has
failed twice, in different ways: once by closing ahead of the delegation and
filing a cross-account gap the platform report had already answered, and once by
a **polling subagent** deciding the journal held complete findings and reporting
back while the task was still `IN_PROGRESS`, closing about ten seconds early.
The skill now keys the exit on the `status` field only, binds the rule to
whoever does the polling, and requires the responder to re-check `status` itself
before writing the root cause.

Whether the responder actually waits is **behaviourally unverified until the
next live `payments-crash` run**. The check is one comparison: the two
investigations' completion timestamps, where the app-team space should close
*after* the platform space it delegated to.

## Where to go next

- [README](../README.md) — what the demo proves today.
- [scenarios.md](scenarios.md) — the fault catalog and per-fault detail.
- [skills-results.md](skills-results.md) — the recorded before/after numbers.
- [aws-devops-agent-integration.md](aws-devops-agent-integration.md) — Agent
  Spaces, delegation shapes, alarm fan-out.
- [architecture.md](architecture.md) — the deployed topology and design
  decisions.
