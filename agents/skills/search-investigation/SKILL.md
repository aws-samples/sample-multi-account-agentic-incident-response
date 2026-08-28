---
name: search-investigation
description: Root-cause procedure for pet search failures or slowness in the
  PetAdoptions backend - shoppers getting empty, erroring or slow search
  results. Use when the firing alarm or the delegated symptom is
  aiops-poc-be-slo-search-latency-p99, aiops-poc-be-slo-search-error-rate,
  aiops-poc-be-infra-search-tasks, or an app-team report that canary alarm
  aiops-poc-fe-golden-journey-duration or aiops-poc-fe-golden-journey-success
  failed on the search step. Covers the search path only - the petsearch-java
  ECS service in cluster PetsiteECS-cluster (latency, error rate, running versus
  desired tasks, FIS stop-task and OOM events) and its DynamoDB pet catalog
  table from SSM /petstore/dynamodbtablename (ThrottledRequests, consumed versus
  provisioned read capacity). Discriminates DynamoDB read throttling (fault id
  ddb-throttle) from ECS task termination and crash loops (fault id
  search-crash). Never name request volume or the load generator as the root
  cause - load is the trigger, the throttle or the crash is the cause.
---

# Search investigation

Use this skill when the reported business symptom is degraded pet search:
search latency above SLO (p95 > 1s) or search availability below SLO
(error rate > 2%).

## Scope rule (read first)

The search path is: `petsite → petsearch-java → DynamoDB`. This path is
independent of the checkout path (payforadoption-go, Aurora) and the
status-update path (SQS → the status-updater Lambda). Do not investigate those
components for search symptoms. If checkout is also failing, a separate
incident likely exists — investigate independently.

`petsearch-java` is an ECS service in the cluster `PetsiteECS-cluster`. The
DynamoDB table name is deployment-generated — resolve it from the SSM parameter
`/petstore/dynamodbtablename` rather than guessing a name.

## Step 1: Confirm the symptom boundary

- Check petsearch-java latency p95 vs SLO (> 1s = breach).
- Check petsearch-java error rate vs SLO (> 2% = breach).
- Determine whether the issue is **slowness**, **errors**, or both — this
  narrows the investigation path.

## Step 2: petsearch-java ECS service

- Service latency and error rate from Application Signals / ADOT metrics.
- Running vs desired task count — are tasks crashing?
- Recent task stop events: look for SIGKILL, OOM, or FIS stop-task events.
- If tasks are being terminated by FIS, root cause is `search-crash`.
- CloudWatch Logs: look for connection errors, timeout patterns, exception
  traces.

## Step 3: DynamoDB (pet catalog)

- ThrottledRequests on the pets table (read throttling).
- ConsumedReadCapacityUnits vs provisioned (or on-demand burst balance).
- If reads are throttled, petsearch-java queries time out or return errors — root
  cause is `ddb-throttle`.
- Check if the upstream dynamo-capacity mechanism has been triggered
  (provisioned capacity reduced).

## Step 4: Distinguish crash vs throttle

| Evidence | Root cause | Fault id |
|---|---|---|
| Tasks terminating, FIS activity, restarts | ECS task crash | `search-crash` |
| DynamoDB ThrottledRequests elevated, tasks healthy | DynamoDB throttling | `ddb-throttle` |
| Both | Multiple faults (unlikely in PoC; report both) | — |

## Step 5: Report

Return findings using the standard report schema (`report-standards` skill):

1. Business impact statement (search availability/latency, duration).
2. Root cause with named fault id and confidence (high/medium/low).
   - `search-crash`: petsearch-java ECS tasks terminated (FIS or crash loop).
   - `ddb-throttle`: DynamoDB read throttling starving search queries.
3. Evidence timeline: metric name, value, threshold, timestamp per claim.
4. Remediation suggestions ranked by confidence. Do not execute changes.
