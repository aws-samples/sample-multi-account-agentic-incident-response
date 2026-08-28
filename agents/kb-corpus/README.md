# Knowledge Base Corpus

Markdown documents ingested into the Bedrock Knowledge Base (S3 data source).
The backend-kb-agent retrieves relevant passages via the Bedrock Retrieve API
and cites them in investigation reports.

## Corpus philosophy

- **Architecture understanding** — how the system is wired, what depends on
  what, which metrics matter for which paths.
- **Scenario investigation guidance** — symptoms, investigation steps,
  evidence patterns, root cause signatures.
- **NO runbooks** — the KB provides grounding context, not step-by-step
  execution scripts. That distinction is what separates the KB agent from the
  skill-based devops agent.

## Documents

| File | Content |
|---|---|
| `petadoptions-architecture.md` | Service topology, request paths, data store ownership, sync/async separation |
| `checkout-latency-scenario.md` | B1 investigation: checkout latency, payforadoption + Aurora path |
| `payments-failure-scenario.md` | B3 investigation: adoption errors, payforadoption crash/chaos modes |
| `search-failure-scenario.md` | B4 investigation: search degradation, petsearch + DynamoDB path |
| `status-update-lag-scenario.md` | B2 investigation: queue age, petstatusupdater + SQS consumer path |
| `fulfillment-backlog-scenario.md` | Listing degradation, shared DynamoDB table impact |

## Ingestion

These files are uploaded to the S3 data source bucket during deployment
(`agents/infra` stack). The Bedrock Knowledge Base syncs from S3 and indexes
the content for semantic retrieval.
