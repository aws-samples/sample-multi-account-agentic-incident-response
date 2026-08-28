---
name: report-standards
description: Required output format for every investigation report produced by
  any agent on this deployment, managed or self-managed. Load it before writing
  the final answer to any alarm-driven incident, on-demand query or delegated
  task. Defines the four mandatory sections - business impact in customer terms
  first (which SLO, observed value versus threshold, duration), root cause with
  a named fault id (payments-crash, payments-error, ddb-throttle, db-overload,
  search-crash, status-consumer-off, checkout-degraded, ui-no-scale) and a
  high/medium/low confidence level, a chronological evidence timeline citing
  metric name, observed value, threshold, UTC timestamp and source for every
  claim, and remediation ranked by confidence with nothing executed. Also
  defines the confidence vocabulary (confirms, indicates, suggests), the rule
  that knowledge-only fallback agents must label documented knowledge as such
  and cap confidence at medium, the self-managed telemetry block, and Knowledge
  Base citation requirements.
---

# Report standards

Every investigation — whether by a managed DevOps Agent space or a
self-managed fallback agent — must produce a report following this structure.

## Required sections

### 1. Business impact

State the customer-facing effect in business terms:

- Which business SLO is breached (e.g., "adoption checkout latency").
- The observed metric value vs the SLO threshold.
- Duration of impact (when it started, whether it is ongoing).
- Customer effect in plain language (e.g., "adopters waiting >3s to complete
  adoption").

Do NOT lead with infrastructure symptoms. Lead with what the customer
experiences.

### 2. Root cause

- **Named fault id** from the scenario catalog (e.g., `db-overload`,
  `payments-crash`, `search-crash`, `ddb-throttle`, `status-consumer-off`,
  `checkout-degraded`, `payments-error`, `ui-no-scale`) where applicable.
- **Confidence level**: `high`, `medium`, or `low`.
  - `high`: direct evidence confirms the cause (e.g., chaos endpoint active in
    logs, FIS experiment visible, event source mapping disabled).
  - `medium`: strong correlation but no direct confirmation (e.g., Aurora
    blocking sessions elevated during the latency breach).
  - `low`: hypothesis based on partial evidence; further investigation needed.
- **Summary**: one-sentence explanation of the mechanism.

### 3. Evidence timeline

A list of evidence items, each with:

- Metric or signal name.
- Observed value.
- Threshold or baseline for comparison.
- Timestamp (UTC).
- Source (CloudWatch metric, log entry, API response) — or, for an agent
  without live access, the runbook or knowledge-base passage the claim rests on,
  marked as documented knowledge rather than observation.

Order chronologically. Every claim in the root cause section must be backed by
at least one evidence item.

### 4. Remediation suggestions

- Ranked by confidence (most confident first).
- State what to do, not how to do it (the operator decides execution).
- Do NOT execute any remediation. Investigation-only.
- Include the expected recovery time if known.

## Confidence language rules

- Use "confirms" only with direct evidence (high confidence).
- Use "indicates" or "correlates with" for medium confidence.
- Use "suggests" or "may indicate" for low confidence.
- Never state certainty without direct evidence.

## Self-managed fallback agents are knowledge-only

The fallback agents (`backend-devops-agent`, `backend-kb-agent`) are reached
over **MCP** — every agent-to-agent link on this deployment is MCP — and each
exposes a single `investigate` tool. They have **no live AWS access and no
telemetry tools**, so their reports:

- Present **documented** likely root causes, the verification checks the owning
  team should run, and remediation guidance — not observed state.
- Must NOT contain observed metric values, log excerpts, or resource states as
  if read live. Where a section calls for evidence, cite the runbook or
  knowledge-base passage that supports the claim, and label it as documented
  knowledge.
- Must NOT claim `high` confidence on the strength of live signals they cannot
  see. `high` requires direct evidence; without live access the ceiling is
  normally `medium`.

The live-telemetry layer is the DevOps Agent (the app-team space for the app
domain, the platform space for the backend domain). Only those reports carry
observed evidence timelines.

## Self-managed agent telemetry block

Fallback agents must additionally include a `telemetry` section in their
structured report:

```json
{
  "telemetry": {
    "round_trips": 1,
    "tokens": 4200,
    "duration_seconds": 38,
    "tool_calls": 0
  }
}
```

`tool_calls` is 0 for these agents by design — they run with no tools
registered. The block still enables the before/after comparison (skills enabled
vs disabled) on round trips, tokens, and duration.

## KB agent citations

When the backend-kb-agent produces a report, it must cite retrieved Knowledge
Base passages using `kb_citations` — a list of document references that
grounded the diagnosis. This distinguishes RAG-grounded reasoning from pure
runbook-following.
