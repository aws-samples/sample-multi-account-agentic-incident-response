# PetAdoptions Architecture Summary

## Overview

PetAdoptions is a microservices-based application deployed across two AWS
accounts demonstrating observability patterns. The application enables users
to browse, search, and adopt virtual pets. It consists of a frontend web
application and multiple backend services communicating via synchronous HTTP
calls and asynchronous message queues.

## Service topology

### Frontend (Account FE)

| Service | Stack | Role |
|---|---|---|
| **petsite** | ECS Fargate + ALB + Autoscaling | Customer-facing web UI; routes user requests to backend services via internal HTTP calls |

petsite reads backend service URLs from SSM Parameters and makes direct HTTP
calls to petsearch and payforadoption. It has no direct database connections.

### Backend services (Account BE)

| Service | Stack | Data store | Role |
|---|---|---|---|
| **petsearch** | ECS Fargate | DynamoDB (petadoptions table) | Handles pet search/browse queries; reads pet listings from DynamoDB |
| **payforadoption** | ECS Fargate | Aurora PostgreSQL | Processes pet adoption checkout and payments; writes adoption records to Aurora |
| **petlistadoptions** | ECS Fargate | DynamoDB | Lists completed adoptions; queries DynamoDB for adoption records |
| **petstatusupdater** | Lambda (SQS consumer) | DynamoDB | Processes adoption status updates asynchronously from SQS; writes status to DynamoDB |

### Data stores (Account BE)

| Store | Service(s) using it |
|---|---|
| **Aurora PostgreSQL** | payforadoption (read/write adoption + payment records) |
| **DynamoDB** (petadoptions table) | petsearch (read), petlistadoptions (read), petstatusupdater (write) |
| **SQS** (status-update queue) | payforadoption (producer) → petstatusupdater (consumer) |

### Supporting infrastructure

- **Traffic generator** — built-in load generator simulating shopper journeys
- **Synthetics canaries** — CloudWatch Synthetics performing end-to-end
  journey health checks
- **Application Signals / ADOT** — distributed tracing and service metrics

## Request paths

### Checkout path (synchronous)

```
petsite (FE) → payforadoption (BE) → Aurora PostgreSQL
```

This is the critical adoption/payment path. Latency or errors in
payforadoption or Aurora directly affect the checkout experience. The entire
chain is synchronous — a slow database query blocks the user's request.

**Key metrics**: payforadoption service latency (p99), Aurora connection count,
Aurora blocking sessions, payforadoption error rate.

### Search path (synchronous)

```
petsite (FE) → petsearch (BE) → DynamoDB
```

Search requests flow from the frontend to petsearch which queries DynamoDB.
DynamoDB throttling or petsearch task crashes directly break search.

**Key metrics**: petsearch latency (p95), petsearch error rate, DynamoDB
consumed capacity, DynamoDB throttled requests.

### Status update path (asynchronous)

```
payforadoption → SQS (status queue) → petstatusupdater → DynamoDB
```

After a successful payment, payforadoption sends a status message to SQS.
petstatusupdater consumes it and writes the updated status to DynamoDB. This
path is decoupled from the checkout flow — a stuck status queue does NOT cause
checkout latency. The queue age IS the business lag metric.

**Key metrics**: SQS ApproximateAgeOfOldestMessage, SQS
ApproximateNumberOfMessages, petstatusupdater invocation errors.

### Listing path (synchronous)

```
petsite (FE) → petlistadoptions (BE) → DynamoDB
```

Retrieves previously completed adoptions. DynamoDB throttling affects listing
availability.

## Critical insight: sync vs async separation

The checkout path and the status-update path share payforadoption as a
starting point but are completely decoupled:

- A slow checkout (B1) is caused by payforadoption or Aurora issues — never
  by SQS or petstatusupdater.
- Stuck status updates (B2) are caused by SQS consumer issues or DynamoDB
  write throttling — never by Aurora or payforadoption latency.

An agent must NOT conflate these paths. Checkout latency investigation should
focus on payforadoption and Aurora. Status lag investigation should focus on
the SQS queue and petstatusupdater.

## Ownership routing (symptom to service)

| Business symptom | Primary owning service | Supporting evidence sources |
|---|---|---|
| Payments declined / checkout errors | payforadoption | Aurora health, payforadoption error logs |
| Checkout slow (latency breach) | payforadoption | Aurora blocking sessions, payforadoption p99 |
| Search failures / slow search | petsearch | DynamoDB throttling, petsearch task health |
| Adoption status delays | petstatusupdater / SQS | Queue age, consumer errors |
| Fulfillment backlog | petlistadoptions / DynamoDB | DynamoDB throttling, listing query latency |
| Page load / journey failures (backend healthy) | petsite (FE) | Autoscaling state, ALB target health |
