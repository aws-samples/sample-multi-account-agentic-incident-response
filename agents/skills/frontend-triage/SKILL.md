---
name: frontend-triage
description: Delegation-first triage procedure for the app-team first responder
  (petsite frontend). Start from the alarm that fired and its tier, then resolve
  locally or delegate to the Platform DevOps Agent via the MCP tool
  aiops-poc-platform-space-mcp_investigate — the only agent with live AWS read
  access to the PetAdoptions backend (payforadoption, petsearch, ECS, Aurora,
  DynamoDB, SQS). Use for every paged incident. Delegation is the default when a
  customer-facing golden signal is breached and the frontend checks out clean;
  never close on request volume or the load generator while a backend dependency
  is unverified. Contains the alarm tier map, the delegate-vs-local decision
  rules, the duplicate-investigation check, the symptom-to-service routing
  table, and the closing procedure — whoever polls, poll the delegated platform
  investigation's status to a terminal value on a bounded wait and fold its
  findings in before the root cause; never file a cross-account gap while a live
  delegation is answering it.
---

# Frontend triage (delegation-first)

You are the **first responder** in the app-team space. Run this skill on every
paged incident, before forming any hypothesis.

**What you can see:** the FE account only — petsite (cluster `aiops-poc-petsite`,
service `petsite`), its ALB, and the shopper-journey canary `aiops-poc-journey`.

**What you cannot see:** anything in the backend account. All 12 `aiops-poc-be-*`
alarms, ECS task state for the backend services, Aurora, DynamoDB and SQS live in
BE, which your space is not associated with. You cannot read that state — the
**Platform DevOps Agent** can, and reaching it is a tool call, not an escalation
ceremony.

**Default outcome:** a customer-facing symptom plus a healthy frontend means
**delegate**. A local conclusion is the exception and needs a named FE resource
limit to justify it.

Every agent-to-agent link on this deployment is **MCP**. There is no A2A path.

---

## Step 1: Identify the alarm and what its tier implies

Detection is **15 CloudWatch alarms in three tiers**; only **5 page**. The alarm
name encodes its origin, and the incident title is `<alarm name> is in ALARM`, so
read the name first.

| Tier prefix | Account | What it measures |
|---|---|---|
| `aiops-poc-fe-golden-*` | FE | Customer-facing golden signal — real user-journey impact. All 3 page **you**. |
| `aiops-poc-be-slo-*` | BE | Per-service business SLO breach (6 alarms). Only `-statusupdate-lag` pages you; the other 5 are actionless evidence you cannot read. |
| `aiops-poc-be-infra-*` | BE | Raw infrastructure "why" evidence (6 alarms). Only `-payments-tasks` pages, and it pages the **platform** space, not you. |

The four alarms that can reach you, and what each one means for triage:

| Alarm | Condition | Triage implication |
|---|---|---|
| `aiops-poc-fe-golden-journey-success` | canary `SuccessPercent` < 90% (1 of 2×60 s) | A journey step failed its assertion. The canary asserts page **content** on search (step 2), housekeeping (step 4a) and checkout (step 4b), so this fires on a backend that returns a fast HTTP 200 error page. Frequently a backend fault wearing a frontend mask. |
| `aiops-poc-fe-golden-journey-duration` | canary `Duration` > 10 000 ms (1 of 2×60 s) | The journey is slow end to end. Either petsite is saturated (local) or a backend dependency is slow (delegate). Step 3 decides which. |
| `aiops-poc-fe-golden-checkout-error-rate` | petsite ALB 5xx rate > 2% (target + ELB 5xx over requests, 2×60 s) | petsite is returning 5xx. petsite is the *messenger*; the checkout path behind it is `petsite → payforadoption-go → Aurora`. |
| `aiops-poc-be-slo-statusupdate-lag` | SQS `ApproximateAgeOfOldestMessage` > 300 s (BE) | An **asynchronous backend** path. The canary journey stays green, so no FE check can confirm or refute it. You have zero telemetry here — go straight to Step 4, rule R4. |

If the alarm carries the `aiops-poc-be-infra-*` prefix, the incident was
mis-routed: that tier belongs to the platform space.

Record the alarm name, tier, observed value, threshold and transition time. Every
later step and the delegation payload reuses them.

---

## Step 2: Check the platform space before opening anything

A `be-infra-*` alarm can open its own investigation in the platform space via the
dual-path alarm fan-out, so a platform investigation may already be running for
the same fault.

1. Call `aiops-poc-platform-space-mcp_list_tasks`.
2. If a task looks related (same fault window, same suspected service), call
   `aiops-poc-platform-space-mcp_get_task` and
   `aiops-poc-platform-space-mcp_list_journal_records` on it and **follow that
   investigation**. Do not open a second one.
3. If nothing related is running, note that fact — it is evidence for Step 4:
   no `aiops-poc-be-infra-payments-tasks` page means backend payments tasks are
   still running.

This step is cheap and it also tells you whether the backend has already
noticed. Do not skip it on the assumption that you are the only responder.

---

## Step 3: Confirm or rule out local (FE) causes

These checks exist to **eliminate** the frontend, not to find a cause. Run all
four and record the result of each — the delegation payload needs them.

1. **petsite ECS**: running vs desired tasks, restart loops, OOM kills, a
   deployment in progress.
2. **petsite ALB**: target response time, 5xx rate, healthy host count.
3. **Canary `aiops-poc-journey`**: which step failed, and whether it failed on
   HTTP status or on a **content** assertion. A content failure points outward.
4. **Application Auto Scaling**: current vs max capacity. Max pinned at the
   current desired count while load is elevated is the local signature
   (`ui-no-scale`).

A healthy ALB and HTTP 200s do **not** clear the backend: petsite renders a
broken backend as a fast 200 error page. Status codes cannot rule out a backend
cause; only the content assertions can.

---

## Step 4: Decision rules

Apply in order; the first match wins.

- **R1 — Local, fully explained.** A golden signal is breached **and** Step 3
  names a specific FE resource limit that accounts for the whole symptom
  (Application Auto Scaling `MaxCapacity` equal to desired under load; petsite
  tasks OOM-killed or restart-looping; a bad petsite deployment) ⇒ resolve
  locally. The control case is `ui-no-scale`. Naming the limit is required — "load
  was high" is not a limit.
- **R2 — Grey failure ⇒ delegate.** A golden signal is breached, Step 3 finds the
  frontend healthy, and Step 2 found no related platform investigation (so no
  `be-infra-*` alarm has paged) ⇒ **delegate**. This is the grey-failure
  signature: customer impact visible only at the edge while the raw infrastructure
  evidence stays quiet. Do **not** conclude locally, and do not treat the quiet
  `be-infra-*` tier as proof the backend is fine — you cannot read that tier;
  its state is one of the things you are asking for.
- **R3 — Platform investigation already open ⇒ join it.** Follow it with
  `get_task` / `list_journal_records`, correlate your FE evidence into your own
  report, and open no second investigation.
- **R4 — `aiops-poc-be-slo-statusupdate-lag` ⇒ delegate unconditionally.** The
  path is asynchronous and invisible to the FE canary. There is no local check
  that can advance this incident.
- **R5 — Mixed or partial evidence ⇒ delegate anyway.** If FE evidence explains
  only part of the symptom (petsite is saturated *and* a dependency looks slow),
  delegate **and** continue local remediation in parallel. Never close on the
  partial local explanation.
- **R6 — Platform provider unreachable ⇒ knowledge-only fallback, capped
  confidence.** See Step 6. Report backend state as **unverified** and keep
  confidence at `medium` or below.
- **R7 — A delegation is not an answer until its `status` is terminal.** R7 is not
  an alternative to R1–R6; it binds *after* whichever of them sent you to Step 5 or
  put you on an existing platform investigation (R2, R3, R4, R5). Once a platform
  investigation is open in your name you own it until `get_task` reports its
  `status` as `COMPLETED` or `FAILED`, or your bounded wait expires — Step 8. The
  gate is that one field and nothing else: **having read the journal does not
  release it, and neither does judging the findings in it complete.** And **R7 binds
  whoever polls** — if you hand the polling to a subagent, the subagent is under
  this rule, and you re-check `status` yourself before you write the root cause
  (Step 8.6).

---

## Step 5: Delegate to the Platform DevOps Agent

The target is the **Platform DevOps Agent** — a second AWS DevOps Agent Agent
Space, associated with the backend account and registered here as an MCP
capability provider. It has **live AWS read access** to payforadoption,
petsearch, ECS, Aurora, DynamoDB and SQS, so it can **confirm** live state:
task counts, target health, error rates, throttles, queue age.

**Call:** `aiops-poc-platform-space-mcp_investigate`
(same provider: `aiops-poc-platform-space-mcp_create_investigation`,
`_get_task`, `_list_tasks`, `_list_journal_records`, plus `_chat` /
`_send_message` for follow-up questions on an open investigation).

**Title** — business symptom first, suspected service named, alarm cited:

```
<business symptom with value vs SLO> — suspect <ECS service from the routing table> (<firing alarm name>)
```

Example: `Shopper journey duration 12.4 s vs 10 s SLO — suspect petsearch-java (aiops-poc-fe-golden-journey-duration)`.

**The request body must contain all five:**

1. **Firing alarm** — name, tier, observed value vs threshold, transition time.
2. **Suspected owning service** — named exactly as in the Step 7 routing table
   (the ECS service name with its language suffix, not the short logical name).
3. **Business symptom** — customer-facing, in business terms, with the number.
4. **FE evidence that rules out the frontend** — the result of each Step 3 check,
   including which canary step failed and whether it failed on content. State
   what you checked and that it was clean; an unstated check reads as a skipped
   check.
5. **Explicit asks** — the live state of `aiops-poc-be-slo-*` and
   `aiops-poc-be-infra-*` for that service, and the state of the dependency
   behind it (Aurora / DynamoDB / SQS). Ask for a named fault id, a confidence
   level, and an evidence timeline per the `report-standards` skill.

---

## Step 6: Knowledge-only fallbacks — second, never first

`backend-devops-agent` (`aiops-poc-backend-devops-agent-mcp_investigate`) and
`backend-kb-agent` (`aiops-poc-backend-kb-agent-mcp_investigate`) are MCP
capability providers with a single `investigate` tool each.

They are **knowledge-only**: no live AWS access, no telemetry tools. They return
documented runbook and knowledge-base guidance — likely causes, the checks the
owning team should run, remediation options — **never observed fact**.

Use them only when the platform investigation is **inconclusive** or the platform
provider is **unavailable** (R6). Do not ask them to read metrics, logs or
resource state. Treat their output as documented knowledge to be verified, and do
not let it raise your confidence to `high`.

---

## Step 7: Symptom-to-owner routing table

Use this to name the suspected owning service when delegating. The backend
services run as ECS services in cluster `PetsiteECS-cluster` (BE account) and
their names carry a language suffix — use these exact names, not the short
logical names used in architecture prose.

| Business symptom | Owning service (BE) | Notes |
|---|---|---|
| Payments declined / checkout errors | `payforadoption-go` | Sync path: petsite → payforadoption-go → Aurora |
| Checkout slow (latency breach) | `payforadoption-go` | Same sync path; latency not errors |
| Search failures / slow search | `petsearch-java` | DynamoDB-backed; also check for ECS task crashes and DynamoDB read throttling |
| Adoption status delays / stale status | Async status-update **path**, not a named function: SQS → status-updater Lambda → DynamoDB | The consuming Lambda is deployment-generated. Resolve it from the **event source mapping on the queue** in SSM `/petstore/queueurl` — do not assert a function name |
| Fulfillment backlog (old messages) | `petlistadoption-py` / DynamoDB | Listing/query backlog; DynamoDB throttling |
| Page load / journey failures with a named FE limit hit | petsite (FE) | Resolve locally under R1 only |

Other service in the same cluster: `petfood-rs` (food and cart pages).

---

## Step 8: Close the delegated investigation before you close your own

A delegation is a **question, not an answer**. R2, R3, R4 and R5 all leave an
investigation running in the platform space, and that investigation is normally
still working after your own FE evidence has stopped moving — on this deployment a
delegated platform investigation reaches a terminal state roughly ten minutes
after it is created. Close ahead of it and the backend confirmation you asked for
lands in *its* report while yours records the same question as unanswerable.

1. **Keep the delegated task id.** `aiops-poc-platform-space-mcp_investigate`
   returns it, and `aiops-poc-platform-space-mcp_list_tasks` recovers it if you
   lose it. Under R3 the id is the investigation you joined.
2. **Poll the `status` field to a terminal value.**
   `aiops-poc-platform-space-mcp_get_task` about once a minute, and read the task's
   **`status`** on every poll. Exactly two things end the wait: `status` is
   `COMPLETED` or `FAILED`, or the bound in 8.4 expires. Nothing else ends it. There
   is no third exit.
3. **Reading the journal while you wait is encouraged, and is not an exit
   condition.** Do read what the investigation has already established with
   `_list_journal_records`, and use `_send_message` / `_chat` to ask for its
   findings so far or to sharpen the question — it makes the wait productive and it
   sharpens your own report. But the journal measures *progress*, never
   *completion*: a platform investigation writes its sub-agents' findings into the
   journal **before** it terminates, so a journal that reads as complete is the
   normal state of a task that is still running. "The journal already contains the
   complete findings" is not a status, and judging the findings comprehensive is not
   a poll result. Neither releases 8.2. Keep polling.
4. **Bound the wait: about 15 polls, roughly 15 minutes from the delegation.**
   Stop as soon as `status` is terminal. Do not poll faster than about once a
   minute, and do not wait past the bound — an unbounded wait turns one slow
   backend investigation into two stalled ones. Urgency does not shorten the bound:
   the bound already *is* the concession to urgency, and 8.7 is what you do when it
   expires.
5. **If a subagent does the polling, the subagent is bound by 8.2–8.4.** Polling is
   a fine thing to delegate, but the exit condition does not survive the hand-off by
   itself — a subagent asked to "poll the platform investigation and report the
   findings" will apply its own judgement about when it has enough. So its
   instruction must carry the exit condition explicitly (`status` is `COMPLETED` or
   `FAILED`, or the poll bound is spent — nothing else, journal completeness
   included), and it must **return the last `status` value it observed and how many
   polls it made**, not only a findings summary. A poll report that arrives without a
   terminal `status` value has not met its brief, however complete its findings look:
   send it back to keep polling, or resume polling yourself. Do not treat its
   findings summary as evidence that the task terminated.
6. **Re-check `status` yourself immediately before you write the root cause.** One
   `aiops-poc-platform-space-mcp_get_task` call, whoever did the polling, so the
   gate rests on a value you observed rather than on a report about a value. Record
   the observed `status` and the time you observed it in your evidence timeline. If
   that check says `IN_PROGRESS` and your bound is not spent, you are back in 8.2.
7. **Fold the answer in.** On `COMPLETED`, read the platform report and carry its
   named fault id, its confidence and its backend evidence into **your** root
   cause and evidence timeline, attributed to the Platform DevOps Agent and marked
   **observed live** — it read that state in the backend account. A question the
   platform space answered is not a gap: if its answer covers everything you
   delegated, file no investigation gap for it.
8. **If the bound expires, or the task ends `FAILED`, close on the delegation as
   in-flight — never as an account gap.** Name the delegated investigation by
   title and id, give the state it was in when you closed (`IN_PROGRESS` or
   `FAILED`), say what you asked it for, and record that as the **open item**. Cap
   confidence at `medium` and mark the backend state **unverified** as in R6.
   Do **not** describe it as missing cross-account access, no backend telemetry, or
   an unreachable backend — an account-boundary gap reason (`aws_account`,
   `gap-backend-account`) is a claim that the question *cannot* be answered here,
   and it is false while an investigation you opened is still answering it. That
   reason is correct in exactly one case: you never got a platform investigation
   open at all (R6).

---

## Failure modes to avoid

These are recorded misses, not hypotheticals.

1. **Never name incoming request volume, the load generator, or "a traffic
   spike" as the root cause.** On a measured run the injected fault was
   `ddb-throttle` (adoptions table cut to 1 RCU / 1 WCU). The investigation
   closed **faster** than baseline with the **wrong** cause — the load
   generator's own request volume — having never reached DynamoDB, consulted no
   other agent, and delegated zero times. Elevated load is a **trigger**. The
   root cause is whatever broke under it.
2. **Volume belongs in a local root cause only with a named FE limit.** `MaxCapacity`
   equal to desired, or a petsite container OOM-killed, is a cause. "Requests
   went up" is context.
3. **Do not close an investigation while the suspected backend dependency is
   unverified.** Unverified means: no answer from
   `aiops-poc-platform-space-mcp_investigate`, or an answer that does not report
   live state for that service. If you could not verify it, say so in the report
   and cap confidence at `medium`.
4. **Do not read silence as health.** 10 of the 15 alarms are actionless
   evidence in the backend account. Nothing paging you means nothing paged — not
   that the backend is fine.
5. **Do not skip Step 2.** Two investigations on one fault split the evidence and
   double the RCA time.
6. **Never file a cross-account visibility gap for a question you have an
   outstanding delegation for.** On a measured run the app-team investigation
   closed **47 seconds before** the platform investigation it had itself delegated
   to, and filed the origin of the change as a cross-account gap — while the
   platform report it was waiting on already carried the CloudTrail confirmation
   of exactly that change. The substance was right and the report was weaker than
   the work. Wait for the answer (Step 8), or close with the delegation named as
   still running. Either is honest; "we could not see into the backend account" is
   not, while your own delegation is in there looking.
7. **Never substitute "the journal looks complete" for a terminal `status`, and
   never let a polling subagent do it either.** On a measured run the polling
   subagent reported back with the platform task still `IN_PROGRESS`, reasoning that
   the journal already held the complete findings from all sub-agents and that the
   incident was urgent — and the app-team investigation closed about ten seconds
   before the platform investigation reached `COMPLETED`. The findings it folded in
   happened to be the final ones, so the root cause was right by luck rather than by
   the procedure. On a slower backend investigation the same reasoning closes on
   partial findings. The journal is progress, `status` is completion, and 8.5–8.6
   are the two checks that keep them apart.

---

## Step 9: Report

Write this only once you have yourself observed the delegated task's `status` as
`COMPLETED` or `FAILED` (Step 8.6), or exhausted the Step 8.4 bound. Produce the
consolidated outcome in the `report-standards` format. Lead
with business impact, then the root cause with fault id and confidence, then the
evidence timeline.

Keep the provenance of every claim visible:

- **Observed live** — your own FE telemetry, and anything the Platform DevOps
  Agent reports from the backend account.
- **Documented knowledge** — anything from a knowledge-only fallback agent.
- **Delegated, still in flight** — anything a platform investigation was still
  working on when your bounded wait expired. Reference that investigation by title
  and id and give its state; it is an open thread, not an account boundary.
- **Unverified** — anything you delegated but never got confirmed, and anything no
  delegation ever covered. Name it as a gap rather than dropping it.
