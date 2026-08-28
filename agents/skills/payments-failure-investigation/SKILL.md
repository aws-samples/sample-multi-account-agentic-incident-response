---
name: payments-failure-investigation
description: Root-cause procedure for adoption payment failures in the
  PetAdoptions backend - adoptions erroring outright, not merely slow. Use when
  the firing alarm or the delegated symptom is
  aiops-poc-be-slo-payments-error-rate, aiops-poc-be-slo-payments-availability,
  aiops-poc-be-infra-payments-tasks, aiops-poc-fe-golden-checkout-error-rate
  (petsite ALB 5xx above 2%), or a canary aiops-poc-fe-golden-journey-success
  failure on the checkout step. Covers the payforadoption-go ECS service in
  cluster PetsiteECS-cluster - target group 5xx and status-code mix, immediate
  errors versus timeout-shaped errors, running versus desired task count, task
  stop reasons (FIS stop-task, SIGKILL, OOM), recent deployments - plus Aurora
  connection exhaustion as a shared dependency. Distinguishes application error
  injection through the chaos endpoint (fault id payments-error) from
  infrastructure task termination (fault id payments-crash). If checkout is slow
  but still succeeding, use checkout-latency-investigation instead.
---

# Payments failure investigation

Use this skill when the reported business symptom is elevated adoption failure
rate (error rate > 2%) — adoptions are failing, not just slow.

## Scope rule (read first)

If checkout is **slow** but the success rate is healthy, switch to
`checkout-latency-investigation`. If the symptom is stale adoption statuses
(queue age), switch to `fulfillment-backlog-investigation`. This skill
covers only the case where adoptions are actively failing.

`payforadoption-go` is an ECS service in the cluster `PetsiteECS-cluster`.
Aurora endpoints and other dependency names are deployment-generated — resolve
them from the `/petstore/*` SSM parameters rather than guessing.

## Step 1: Confirm the symptom boundary

- Compare adoption success rate vs SLO (> 2% errors = breach).
- Check checkout latency: if latency is also breaching (timeouts causing
  errors), the latency skill may lead — but if errors are immediate (not
  timeout-shaped), stay here.

## Step 2: payforadoption-go service errors

- Target group 5xx rate and HTTP status code distribution.
- Service error rate from Application Signals / ADOT metrics.
- Discriminate **timeout errors** (latency-driven, 504/timeout) from
  **immediate errors** (500, application-level 4xx, crash restarts).

## Step 3: Application error mode (chaos endpoint)

- Check service logs for activated error/chaos modes — the payforadoption-go
  service has a built-in chaos endpoint that can inject errors on demand.
- If the chaos endpoint is activated, root cause is `payments-error`.

## Step 4: ECS task health

- Running vs desired task count — are tasks crashing and restarting?
- Recent task stop events: look for SIGKILL, OOM, or FIS stop-task events.
- If tasks are being terminated by FIS (Fault Injection Service), root cause
  is `payments-crash`.
- Deployment events: was a bad deployment rolled out?

## Step 5: Aurora (downstream)

- If errors are connection-related (connection pool exhausted, connection
  refused), check Aurora availability and connection count.
- This is less common for failure scenarios but rules out a shared dependency.

## Step 6: Report

Return findings using the standard report schema (`report-standards` skill):

1. Business impact statement (adopter-facing effect, failure rate, duration).
2. Root cause with named fault id and confidence (high/medium/low).
   - `payments-error`: chaos endpoint activated (application error injection).
   - `payments-crash`: ECS tasks terminated by FIS or crashing.
3. Evidence timeline: metric name, value, threshold, timestamp per claim.
4. Remediation suggestions ranked by confidence. Do not execute changes.
