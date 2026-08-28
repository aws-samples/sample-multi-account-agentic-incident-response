# Scenario: Status Update Lag Investigation

## Business symptom

Pet adoption status updates are delayed (SQS queue age > 300 seconds).
Adopters see stale status for their adoption — the transaction completed
but the status page still shows "processing."

## Affected request path

```
payforadoption → SQS (status-update queue) → petstatusupdater → DynamoDB
```

This is an asynchronous path. It is completely decoupled from the checkout
request/response cycle.

## Critical understanding: decoupled from checkout

The status update path shares payforadoption as its origin (it publishes a
message after a successful payment) but the queue processing is independent.

- A stuck status queue does NOT cause slow checkouts.
- Slow checkouts do NOT cause status update lag.
- The queue age IS the business metric — it directly measures how stale
  status information is.

## Investigation procedure

### Step 1: Confirm the symptom

Check SQS metrics for the status-update queue:
- `ApproximateAgeOfOldestMessage` > 300 seconds confirms the lag
- `ApproximateNumberOfMessages` — is the backlog growing?

### Step 2: Check the consumer (petstatusupdater)

petstatusupdater is a Lambda function triggered by SQS:
- Is the function being invoked?
- Are invocations erroring?
- Is the SQS event source mapping enabled?
- Has the function been throttled?

### Step 3: Check DynamoDB write capacity

petstatusupdater writes to DynamoDB:
- Are writes being throttled?
- Is the table healthy and ACTIVE?

### Step 4: Identify known fault patterns

- `status-consumer-off`: The SQS event source mapping for petstatusupdater
  has been disabled. Messages accumulate in the queue with no consumer. The
  queue age grows linearly. Checkout continues to work fine (payments still
  succeed, they just can't update status).

### Step 5: Rule out unrelated factors

- Aurora health is NOT relevant (status updates use DynamoDB, not Aurora)
- payforadoption latency is NOT the cause (it successfully published the
  message; the problem is downstream)
- petsearch health is NOT related

## Root cause patterns

| Evidence | Likely root cause | Confidence |
|---|---|---|
| SQS messages growing + petstatusupdater not invoking | Consumer disabled (status-consumer-off) | High |
| petstatusupdater errors + DynamoDB throttled writes | Write capacity issue | Medium |
| petstatusupdater timeout errors | Processing bottleneck | Medium |
| Queue age high but messages count stable | Slow but functioning consumer | Low |

## Key insight for agents

The most common mistake is conflating this with checkout issues because both
involve payforadoption. Remember: payforadoption PRODUCES the message, but
the problem is always on the CONSUMER side (petstatusupdater or DynamoDB
writes). If checkout is working fine but status is stale, look at the
consumer, not the producer.
