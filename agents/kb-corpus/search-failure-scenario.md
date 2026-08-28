# Scenario: Search Latency or Failure Investigation

## Business symptom

Pet search becomes slow (p95 > 1 second) or unavailable (error rate > 2%).
Shoppers cannot browse available pets or experience degraded search results.

## Affected request path

```
petsite (FE) → petsearch (BE) → DynamoDB (petadoptions table)
```

Synchronous path. petsearch reads pet data from DynamoDB and returns results
to petsite.

## Investigation procedure

### Step 1: Confirm the symptom

Check petsearch service metrics:
- Service latency (p95) — is it exceeding 1 second?
- Error rate — are requests failing?
- Is the degradation sustained or transient?

### Step 2: Check petsearch service health

- Running vs desired task count in ECS
- Task crashes or restarts
- CPU/memory utilization
- Recent deployments

### Step 3: Investigate DynamoDB

The search path depends entirely on DynamoDB:
- **Throttled requests**: Check `ThrottledRequests` metric. If provisioned
  throughput is exceeded, reads are throttled and petsearch gets slow or
  error responses.
- **Consumed capacity**: Compare consumed vs provisioned read capacity.
- **Table status**: Confirm the table is ACTIVE.

### Step 4: Identify known fault patterns

- `ddb-throttle`: The upstream dynamo-capacity mechanism reduces provisioned
  throughput, causing read throttling under normal load. This directly slows
  or fails search queries.
- `search-crash`: FIS experiment stops petsearch tasks. With no healthy
  targets, the ALB returns 503 for all search requests.

### Step 5: Rule out unrelated paths

- Aurora health is NOT relevant to search (search uses DynamoDB)
- SQS queue metrics are NOT relevant to search
- payforadoption health is NOT relevant to search

## Root cause patterns

| Evidence | Likely root cause | Confidence |
|---|---|---|
| DynamoDB ThrottledRequests elevated + petsearch latency/errors | DynamoDB throughput throttling (ddb-throttle) | High |
| petsearch tasks at 0 or crashing + ALB 503s | Service crash (search-crash via FIS) | High |
| petsearch healthy + DynamoDB healthy + latency high | Unusual query patterns or hot partitions | Medium |

## Important distinctions

- Search uses DynamoDB, NOT Aurora. Do not investigate Aurora for search issues.
- The petlistadoptions service also uses DynamoDB — if DynamoDB is throttled,
  both search and listing may be affected simultaneously.
