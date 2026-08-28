# Skills before/after — results

The third demo axis in [skills.md](skills.md) is simple: inject the same fault
twice and compare how the DevOps Agent Agent Spaces do it with and without the
repo's skill catalog. **`ddb-throttle`, `payments-crash` and `search-crash` all
have valid skills-ON results now.** Everything recorded before the
`["GENERIC"]` re-upload is an OFF baseline, including the `ddb-throttle` run
previously labelled ON: the catalog was uploaded with
`agent_types: ["INCIDENT_TRIAGE"]`, which scopes a skill to the
decide-whether-to-investigate phase, so the runbooks were never eligible during
root-cause analysis and never loaded — the only bundle seen loading in those runs
is the service's own `understanding-agent-space`. See
[skills.md](skills.md#agent-types--the-field-that-silently-disables-a-skill).

One rule for the ON half: the only thing that changes is the per-skill
**Active / Inactive** toggle in the Agent Space console. Leave the SSM parameter
`/aiops-poc/skills-enabled` at `true` — it gates only the self-managed Strands
fallback agents, so touching it adds a second variable and breaks the pair.

Times are as recorded. Time to RCA is investigation created → terminal state.
Time to detect — inject (T0) to the first paging alarm transition — is a
different clock; don't add the two, and note it is a control variable here, not
part of the before/after comparison (see the line under the table). Full
timelines live in [deployment.md](deployment.md#run-log).

## Comparison

| Scenario | Fault | Time to RCA (Skills OFF) | Time to RCA (Skills ON) | Cross-space MCP calls | RCA correct? | Fallback consulted |
|---|---|---|---|---|---|---|
| B3 `payments-crash` | Payments tasks stopped (FIS) | app-team 9 min 51 s (FAILED)<br>platform 7 min 50 s (COMPLETED) | app-team **10 min 43 s** (COMPLETED; delegated platform investigation 7 min 14 s, in parallel)<br>platform 5 min 23 s from its own page (COMPLETED) | **0 → 3 (1 delegation)** | OFF app-team no (empty root cause), platform yes<br>ON yes in all three — FIS stop-task named outright | devops runbook agent ×1 + KB agent ×1 (ON); its answer (`payments-error`) was **not** adopted |
| B4 `ddb-throttle` | Adoptions table cut to 1 RCU / 1 WCU | 19 min 43 s (COMPLETED) | **11 min 57 s (run 1) / 14 min 01 s (run 2)** (both COMPLETED; delegated platform investigation 10 min 18 s / 10 min 12 s, in parallel) | **0 → 31 run 1 / 26 run 2 (1 delegation each)** | yes in all three — OFF as a high-confidence hypothesis, ON as a confirmed root cause from backend telemetry both times | devops runbook agent ×2 (OFF), ×1 per ON run |
| B4 `search-crash` | PetSearch tasks stopped | 20 min 33 s (COMPLETED) | app-team **10 min 39 s** (COMPLETED; delegated platform investigation 6 min 40 s, in parallel) | **0 → 15 (1 delegation)** | yes both — OFF as PetSearch 503, explicitly not throttling; ON as the stopped ECS tasks themselves from backend telemetry, throttling ruled out on zero throttle events | OFF not recorded; **ON none** — the platform space answered, so no fallback consult was needed |

On the cross-space call counts: every ON run delegated **exactly once** — one
`_investigate` call, preceded by one `_list_tasks` duplicate check — and all
remaining calls are the app-team responder polling the delegated investigation to
read its findings back (29 of 31 and 24 of 26 on `ddb-throttle`, 13 of 15 on
`search-crash`, 1 of 3 on `payments-crash`, one of the `ddb-throttle` run 2 calls
being a `_send_message`). The totals are floors, not exact counts: where a
polling subagent did the reading, its calls are not itemized in the parent
investigation's utilization record, which is why `payments-crash` shows 3 and
`ddb-throttle` 31 — less polling by the parent, not less delegation. The number
that matters is 0 versus non-zero: delegation never once fired in any skills-OFF
run.

Detection is a control variable, not a skills effect: it is alarm- and
canary-driven and never reads the skill catalog. Recorded at 1 min 00 s to
1 min 45 s for the two task-stop faults — `payments-crash` and `search-crash`,
both detected by `fe-golden-journey-success` — and 4 min 23 s to 4 min 42 s for
`ddb-throttle`, detected by `fe-golden-journey-duration`, with the OFF/ON
differences inside the 1-minute canary granularity.

`payments-crash` OFF numbers are from the most recent baseline run only. The four
earlier runs used different alarm and canary wiring (5-minute canary, actionable
backend SLO alarms, single-path fan-out), so they aren't comparable and aren't
listed. The two investigations in that run came from one alarm fanning out to two
webhooks, not from delegation.

`payments-crash` also has a valid skills-ON result now, and it moved the one
number that mattered: the app-team investigation **COMPLETED** instead of
FAILING with an empty root cause, and it named the FIS experiment as the cause.
It got there by delegating — the duplicate-investigation check ran first, found
nothing open in the platform space (the backend infra alarm had not paged yet,
one minute later it did), so the responder opened a platform investigation and
adopted its finding. Three investigations existed in total: the app-team one, the
platform one it delegated, and the platform one the backend infra alarm opened on
its own a minute later. The devops runbook agent was consulted in parallel and
answered `payments-error` with high confidence, which is wrong; the responder
kept the backend telemetry answer instead.

**`payments-crash` ON reproduced too, and on the other delegation shape.** A second
ON run of the same scenario delegated again, but this time the duplicate check found
a platform investigation already open — the BE infra alarm had paged about 45 seconds
after the FE golden signal — so the responder applied the join rule instead of
opening one: `_list_tasks`, `_get_task` and `_list_journal_records` once each, plus a
dedicated polling subagent, and the platform space's live RCA (CloudTrail attribution
of the FIS experiment, the stop-task selection mode, the re-kill cadence) is what set
the app-team space's final root cause. Both spaces COMPLETED on `payments-crash`,
about ten seconds apart, and both loaded their per-space skills. The runbook fallback
was consulted in parallel and returned the right fault at medium confidence from
documented knowledge, with the responder recording that the platform investigation
was the one able to confirm it. So `payments-crash` now covers both delegation
shapes — open-your-own and join-the-open-one — and which one you get is a race
between the responder's duplicate check and the BE alarm's page, not a setting. One
defect in it: the polling subagent reported back while the platform task was still
`IN_PROGRESS`, and the app-team investigation closed about ten seconds ahead of the
space it was waiting on. `frontend-triage` Step 8 now keys the wait on the delegated
task's `status` field and binds whoever polls; whether the responder actually waits
is behaviourally unverified until the next run.

`ddb-throttle` now has a valid skills-ON result, the first in this PoC. **The
skills loaded**: the app-team journal lists `frontend-triage` and
`report-standards` in `skills.bundles` next to `understanding-agent-space`, and
the platform space loaded `search-investigation` and
`checkout-latency-investigation`. **And delegation fired** — app-team →
platform, 31 platform-space MCP calls against 0 in every earlier run, with the
duplicate-investigation check the new skill prescribes running first. Detection
is unchanged (the alarm is not skill-dependent); RCA is 7 min 46 s faster and
lands harder: OFF could only offer DynamoDB throttling as a hypothesis from the
frontend account, ON confirmed the capacity reduction itself from backend
telemetry. The load generator's request volume was not blamed. Fallback use
halved, to one supplementary consult.

**And it reproduced.** A second ON run on the same scenario repeated every
behaviour that mattered: `frontend-triage` and `report-standards` loaded again,
the duplicate-investigation check ran first and found nothing open, the
responder delegated on the same grey-failure rule, and the platform space
returned the capacity reduction as the confirmed root cause from backend
telemetry — again with the load generator's request volume not blamed. RCA
landed at 14 min 01 s against 11 min 57 s, slower than the first ON run but
still well inside the 19 min 43 s OFF baseline; the delegated platform
investigation came in at 10 min 12 s against 10 min 18 s, and cross-space traffic
held at 26 calls against 31 for the same single delegation. The one difference worth naming: this time the app-team
report filed the *origin* of the capacity change as a cross-account gap while
the platform investigation it delegated to had already confirmed it, so the
CloudTrail confirmation sat in the platform report rather than the app-team one.
The supplementary runbook consult happened once again, and this time its answer
(`ddb-throttle`) was right.

The earlier run once recorded as ON (12 min 06 s, COMPLETED, root cause "the
load generator's own request volume") was **not** measuring the catalog. Every
skill had been uploaded with
`agent_types: ["INCIDENT_TRIAGE"]`, so none was eligible during root-cause
analysis — the phase the run spent its time in — and the journal shows what that
looks like: no uploaded skill loaded anywhere, only the service's own
`understanding-agent-space`, exactly as in every OFF run. That number is a second
OFF baseline with the toggle flipped, not an ON result. The 7 min 37 s speedup
and the wrong conclusion both belong to a space without its catalog. The four
backend runbooks were also in the platform space, which was never reached
(0 delegations), so they would have been out of scope even with the right agent
types. Re-run required after the `["GENERIC"]` re-upload.

## Running the ON half comparably

- Confirm the catalog is actually loadable before you start: every USER skill
  ACTIVE **and** `agent_types` = `GENERIC` in both spaces
  (`scripts/upload-skills.sh` prints both columns). `INCIDENT_TRIAGE` there means
  the runbooks will not load during RCA, and the run is wasted.
- After the run, check the investigation journal names an uploaded skill. If the
  only bundle listed is `understanding-agent-space`, the catalog did not load and
  the result is another OFF baseline.
- Inject the fault first, then start load — at full capacity the table banks
  unused read credit and throttles won't appear until it drains.
- Load for `ddb-throttle`: `./loadgen/run.sh --paths search`. Do **not** use
  `--rate 50`; it OOM-kills the petsite container and produces zero throttles,
  so the load becomes the fault.
- Keep a quiet window of about an hour before T0. No calibration load, no alarm
  transitions, canary passing steadily. A prior load storm dominates the RCA.
- Restore afterwards with `./chaos/scripts/restore.sh <scenario>` and confirm the
  original capacity, cleared chaos markers and a passing canary.
- Full procedure, preconditions and verification steps:
  [deployment.md](deployment.md).

## The caveat that mattered

App-team → platform space delegation had **never fired** before the loaded
catalog: 0 invocations in every skills-OFF run, and sharpening the MCP
description or adding dual-path alarm routing moved nothing. The `ddb-throttle`
ON run is the first with a non-zero count — the responder ran the
duplicate-investigation check, applied the skill's grey-failure rule and opened a
platform investigation.

**It generalised to a second scenario.** `payments-crash` ON delegated too, on a
different fault shape (hard outage instead of grey failure) and on a different
alarm, again after running the duplicate check first. That converts the app-team
failure mode — blind at the account boundary, empty root cause — into a completed
investigation with the correct cause.

**And to a third.** `search-crash` ON delegated as well, on the one scenario with
no infra paging path at all — the platform space is never paged here, so the only
way it gets involved is the app-team responder calling it. The duplicate check ran
first, found nothing open in the platform space, and the responder opened one and
adopted its answer; RCA came in half the OFF time and named the stopped tasks
rather than the 503 they produced. Three scenarios, three shapes, and one of them
with delegation as the sole route into the backend, so routing is a repeatable
result rather than a single observation.

**It is also reproduced on the same scenario, not only generalised across three.**
`ddb-throttle` was run ON twice, and the second run delegated on the same rule
after the same duplicate check, loaded the same skills, and reached the same
correct root cause from backend telemetry. So the routing result now rests on
both a repeat of one scenario and a spread across three fault shapes, rather than
on one observation per scenario.

## Excluded scenarios

- **B5 `ui-no-scale`** — no usable baseline; no investigation was ever created
  from a real fault, only from a forced alarm.
- **B2 `status-consumer-off`** — cannot fire on this deployment; the status queue
  receives no messages, so lag never builds.
- **B1 `checkout-degraded`** — needs endpoints that are absent from the deployed
  images.

Scenario definitions: [scenarios.md](scenarios.md). Skill catalog and toggles:
[skills.md](skills.md).
