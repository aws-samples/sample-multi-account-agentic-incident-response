# Scenario: Fulfillment Backlog Investigation

## Business symptom

Pet listing/query performance is degraded. The petlistadoptions service is
slow or timing out, causing the adoption history view to be unavailable or
stale.

## Affected request path

```
petsite (FE) → petlistadoptions (BE) → DynamoDB (petadoptions table)
```

Synchronous read path. petlistadoptions queries DynamoDB for completed
adoption records.

## Investigation procedure

### Step 1: Confirm the symptom

Check petlistadoptions metrics:
- Service latency elevation
- Error rate increase
- Request throughput changes

### Step 2: Check petlistadoptions service health

- ECS task status (running, desired, pending)
- Recent task restarts or crashes
- Recent deployments

### Step 3: Investigate DynamoDB

petlistadoptions and petsearch share the same DynamoDB table:
- **Read throttling**: Check if consumed read capacity exceeds provisioned.
- **ThrottledRequests metric**: Elevated throttling directly causes listing
  failures or slowness.
- **Table status**: Confirm ACTIVE.

### Step 4: Correlation with search issues

Because petsearch and petlistadoptions share the DynamoDB table, a DynamoDB
throttling issue (e.g., from ddb-throttle fault) can affect BOTH services
simultaneously. If both search and listing are degraded, the root cause is
likely DynamoDB-level.

### Step 5: Rule out unrelated paths

- Aurora is NOT used by petlistadoptions (it uses DynamoDB)
- SQS queue metrics are NOT relevant to listing queries
- payforadoption health is NOT relevant

## Root cause patterns

| Evidence | Likely root cause | Confidence |
|---|---|---|
| DynamoDB throttling + both search and listing degraded | DynamoDB throughput throttling (ddb-throttle) | High |
| petlistadoptions tasks unhealthy or crashing | Service issue | Medium |
| DynamoDB healthy + service healthy + latency high | Hot partition or scan-heavy queries | Low |

## Shared infrastructure note

The petadoptions DynamoDB table is shared between petsearch (reads for
search), petlistadoptions (reads for listing), and petstatusupdater (writes
for status). A capacity issue at the table level can manifest as degradation
across multiple business functions simultaneously.
