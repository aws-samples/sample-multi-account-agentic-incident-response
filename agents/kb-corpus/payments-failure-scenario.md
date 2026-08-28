# Scenario: Payments/Adoption Failure Investigation

## Business symptom

Adoption success rate drops below threshold (> 2% errors over 3 minutes).
Shoppers experience failed adoptions — transactions that do not complete.

## Affected request path

```
petsite (FE) → payforadoption (BE) → Aurora PostgreSQL
```

Same synchronous path as checkout latency, but the failure mode is errors
rather than slowness.

## Investigation procedure

### Step 1: Confirm the symptom

Check payforadoption error rate metrics:
- Error responses (5xx) from the service
- Elevated error ratio compared to baseline

### Step 2: Check payforadoption service health

- Are tasks running and healthy?
- Any recent task crashes or restarts?
- Is the service responding at all, or is it fully down?

### Step 3: Differentiate error sources

- **Service-level errors (chaos endpoint)**: The payforadoption chaos/error
  endpoint returns synthetic error responses. The service is running but
  returning failures.
- **Service unavailable (crash)**: If payforadoption tasks are stopped or
  crashing, no requests succeed. ALB returns 503 because there are no
  healthy targets.
- **Database errors**: Aurora connection failures or write errors propagate
  as 500s from payforadoption.

### Step 4: Check Aurora connectivity

- Can payforadoption reach Aurora?
- Are there connection pool exhaustion symptoms?
- Any Aurora failover events?

## Root cause patterns

| Evidence | Likely root cause | Confidence |
|---|---|---|
| payforadoption returning errors + tasks healthy + Aurora healthy | Chaos error mode active (payments-error) | High |
| payforadoption tasks at 0 or restarting + ALB 503s | Service crash (payments-crash via FIS) | High |
| Aurora unreachable or failing writes | Database connectivity issue | Medium |
| Intermittent errors correlating with load | Capacity exhaustion | Medium |

## Distinction from checkout latency

- Checkout latency (B1): requests succeed but are slow
- Payments failure (B3): requests fail entirely
- The investigation paths overlap (same service chain) but the evidence
  signature differs — latency metrics vs error rate metrics.
