---
name: fulfillment-backlog-investigation
description: Root-cause procedure for stale adoption statuses and fulfillment
  backlog in the PetAdoptions backend - an adoption completes but its status
  never updates. Use when the firing alarm or the delegated symptom is
  aiops-poc-be-slo-statusupdate-lag (SQS ApproximateAgeOfOldestMessage above
  300 s), a growing status-queue backlog, or stale pet statuses while checkout
  latency and success rate are both within SLO. Covers the asynchronous path
  only - the status queue resolved from SSM /petstore/queueurl (messages sent
  versus received, backlog depth), its consumer Lambda resolved from the queue's
  event source mapping rather than by guessing the logical name
  petstatusupdater (mapping state, invocations, errors, throttles, duration),
  and the DynamoDB status table (write throttling). Distinguishes fault id
  status-consumer-off from fault id ddb-throttle. Explicitly excludes the
  synchronous checkout path (payforadoption-go, Aurora), which queue backup
  cannot delay.
---

# Fulfillment backlog investigation

Use this skill when the reported business symptom is elevated queue age
(ApproximateAgeOfOldestMessage > 300s on the status queue) or stale adoption
statuses while checkout itself is healthy.

## Scope rule (read first)

The status-update path is asynchronous: `payforadoption-go → SQS → the
status-updater Lambda → DynamoDB`. This path CANNOT affect checkout latency or
success rate. If checkout is also breaching, switch to
`checkout-latency-investigation` or `payments-failure-investigation` — those
symptoms have different owners.

**Resolve the consumer, do not name it.** The queue and its consumer function
are deployment-generated. Read the queue URL from the SSM parameter
`/petstore/queueurl`, then list the event source mappings for that queue's ARN
and take the function from the mapping. Architecture prose calls this component
`petstatusupdater`; that is a logical name and does not match any deployed
function. A function whose *name* looks like the status updater may exist with no
event source mapping at all, so a name-based lookup points at the wrong resource.

## Step 1: Confirm the symptom boundary

- Check SQS ApproximateAgeOfOldestMessage on the status-update queue
  (`/petstore/queueurl`).
- Verify checkout latency and success rate are within SLO (rules out a shared
  upstream issue in payforadoption-go).

## Step 2: SQS queue metrics

- ApproximateNumberOfMessagesVisible (backlog depth).
- NumberOfMessagesSent vs NumberOfMessagesReceived (production vs consumption
  rate).
- If messages are being sent but not received, the consumer is the problem.

## Step 3: The consumer (Lambda, resolved from the event source mapping)

- Check the SQS event source mapping on the queue: is its state `Enabled`? If
  disabled, root cause is `status-consumer-off`.
- The consumer is a **Lambda function, not an ECS service**: look at
  Invocations, Errors, Throttles, Duration, and concurrency — there are no
  task counts or OOM kills to check here.
- CloudWatch Logs for that function: processing errors, DynamoDB write
  failures, throttling exceptions.
- If Invocations are flat at zero while the queue holds messages, the mapping
  or its permissions are the problem, not the function code.

## Step 4: DynamoDB (status table)

- ThrottledRequests on the status table.
- ConsumedWriteCapacityUnits vs provisioned (or on-demand burst balance).
- If writes are throttled, the consumer cannot drain the queue — root cause is
  DynamoDB throttling downstream.

## Step 5: Report

Return findings using the standard report schema (`report-standards` skill):

1. Business impact statement (status freshness effect, duration).
2. Root cause with named fault id and confidence (high/medium/low).
   - `status-consumer-off`: event source mapping disabled.
   - `ddb-throttle`: DynamoDB write throttling starving the consumer.
3. Evidence timeline: metric name, value, threshold, timestamp per claim.
4. Remediation suggestions ranked by confidence. Do not execute changes.
