---
name: checkout-latency-investigation
description: Root-cause procedure for slow adoption checkout in the PetAdoptions
  backend - adopters waiting on the pay/adopt step while adoptions still
  succeed. Use when the firing alarm or the delegated symptom is checkout p99
  latency above SLO (aiops-poc-be-slo-checkout-latency-p99), or an app-team
  report that the shopper-journey canary alarm
  aiops-poc-fe-golden-journey-duration traces to the checkout step. Covers the
  synchronous path only - the payforadoption-go ECS service in cluster
  PetsiteECS-cluster (service latency p99, target group response time, task
  count, activated chaos/degradation endpoint) and its Aurora PostgreSQL
  database (CPU, connections, blocking and waiting sessions, lock waits,
  Performance Insights top SQL). Distinguishes fault id checkout-degraded from
  fault id db-overload. Excludes the asynchronous status-update path (SQS, the
  status-updater Lambda, DynamoDB), which cannot slow a checkout response. If
  adoptions are failing rather than slow, use payments-failure-investigation
  instead.
---

# Checkout latency investigation

Use this skill when the reported business symptom is elevated adoption
checkout latency (checkout p99 above SLO) while the adoption success rate
remains healthy.

## Scope rule (read first)

Checkout is synchronous: `petsite → payforadoption-go → Aurora`. The
status-update path (`payforadoption-go → SQS → the status-updater Lambda →
DynamoDB`) is asynchronous and CANNOT delay checkout responses. Do not spend
tool calls on queue depth or the status-updater Lambda for this symptom. If
evidence later points at status lag instead, switch to
`fulfillment-backlog-investigation`.

The backend services run as ECS services in the cluster `PetsiteECS-cluster`;
the checkout service is `payforadoption-go`. Aurora, DynamoDB, and SQS names are
deployment-generated — resolve them from the `/petstore/*` SSM parameters rather
than guessing.

### PCI DSS note

The `payforadoption-go` path is named for a payment step but handles no
cardholder data in this PoC: it records a synthetic adoption transaction, and
no PAN, CVV or payment credential is collected, transmitted or stored. Nothing
in this procedure requires reading transaction payloads — investigate latency
from metrics (service p99, target-group response time, task count) and database
telemetry only, never by dumping request bodies or table rows.

If you adapt this skill to a workload that genuinely processes cardholder data,
PCI DSS applies to that environment and defining and validating its scope is
the deploying customer's responsibility under the AWS shared responsibility
model. See https://aws.amazon.com/compliance/pci-dss-level-1-faqs/.

## Step 1: Confirm the symptom boundary

- Compare checkout latency p99 vs SLO (> 2s = breach) over the last 30
  minutes.
- Check the adoption success rate: if it is also breaching, switch to
  `payments-failure-investigation` (failures, not slowness, lead).

## Step 2: payforadoption-go service

- Service latency p99 vs baseline, target group response time, request count.
- Running vs desired task count and recent deployment events.
- Service logs: look for enabled degradation/chaos modes or slow downstream
  call warnings — root cause `checkout-degraded` if the built-in degradation
  endpoint has been activated.

## Step 3: Aurora PostgreSQL

- CPU, connections, and blocking/waiting sessions vs baseline.
- Performance Insights top SQL: lock waits, long-running statements.
- Lock-generating or slow-query load indicates root cause `db-overload`.

## Step 4: Distinguish degraded vs overloaded

| Evidence | Root cause | Fault id |
|---|---|---|
| Chaos/degradation endpoint active in logs | App-level slowdown | `checkout-degraded` |
| Aurora blocking sessions, lock waits elevated | Database contention | `db-overload` |
| Both (unlikely in PoC) | Report both | — |

## Step 5: Report

Return findings using the standard report schema (`report-standards` skill):

1. Business impact statement (adopter-facing effect, duration).
2. Root cause with named fault id and confidence (high/medium/low).
   - `checkout-degraded`: payforadoption-go chaos/degradation endpoint activated.
   - `db-overload`: Aurora blocking sessions from lock-generating workload.
3. Evidence timeline: metric name, value, threshold, timestamp per claim.
4. Remediation suggestions ranked by confidence. Do not execute changes.
