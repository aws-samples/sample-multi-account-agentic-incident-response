# Scenario: Checkout Latency Investigation

## Business symptom

Adoption checkout latency exceeds the SLO threshold (p99 > 2 seconds for 3
minutes). Shoppers experience slow completion of pet adoption transactions.

## Affected request path

```
petsite (FE) → payforadoption (BE) → Aurora PostgreSQL
```

This is a synchronous path. Every millisecond added at the database or
service layer is directly felt by the end user.

## Investigation procedure

### Step 1: Confirm the symptom

Check payforadoption service latency metrics. Look for:
- p99 latency exceeding 2 seconds
- Sustained elevation over 3+ minutes
- Correlation with increased traffic or sudden spike

### Step 2: Check payforadoption service health

Examine the ECS service:
- Running vs desired task count
- Recent deployments (could indicate a bad deploy)
- Task restarts or OOM kills
- CPU and memory utilization trends

### Step 3: Investigate Aurora database

The most common cause of checkout latency is database pressure:
- **Blocking sessions**: Lock contention from concurrent writes. High
  `BlockingSessionCount` indicates transactions waiting on locks.
- **Connection count**: If approaching max connections, new requests queue.
- **Slow queries**: Check for queries exceeding normal execution time.
- **IOPS/throughput**: Storage saturation can slow all operations.

### Step 4: Check for chaos/load conditions

Known fault patterns that cause checkout latency:
- `checkout-degraded`: The payforadoption built-in chaos endpoint introduces
  artificial delay in the payment processing path.
- `db-overload`: Upstream DB load simulators generate lock-heavy workloads on
  Aurora, causing blocking sessions that queue legitimate payment writes.

### Step 5: Rule out unrelated paths

- SQS queue age is NOT relevant to checkout latency (async path)
- DynamoDB throttling affects search, not checkout
- petstatusupdater issues affect status updates, not checkout

## Root cause patterns

| Evidence | Likely root cause | Confidence |
|---|---|---|
| Aurora blocking sessions elevated + payforadoption latency high | Database lock contention (db-overload) | High |
| payforadoption latency high + Aurora healthy | Service-level degradation (checkout-degraded) | High |
| payforadoption tasks restarting | Service crash/instability | Medium |
| All metrics normal but latency intermittently high | Load-induced queuing | Medium |

## Important: what this scenario is NOT

- This is NOT about payment failures (error rate) — that is a separate
  scenario (payments-error, payments-crash).
- This is NOT about status update delays — the status path is asynchronous
  and decoupled from checkout.
