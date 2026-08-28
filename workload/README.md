# workload — PetAdoptions across two accounts

For the operator replicating this demo: what the workload is, how it is split
across two accounts, the resource and telemetry names the rest of the repo
depends on, and what to check after the backend deploy finishes.

The e-commerce workload is the AWS One Observability Workshop
[PetAdoptions](https://github.com/aws-samples/one-observability-demo)
application, **split across two accounts so each DevOps agent's knowledge
boundary is a real account boundary**:

| Account | Runs | How it is deployed |
|---|---|---|
| **BE** (backend) | Full upstream PetAdoptions, unforked: petsearch, payforadoption, petlistadoption, petstatusupdater, petfood, DynamoDB, Aurora, SQS, traffic generator, canaries — plus the upstream's own petsite copy, which is left running (see the accepted delta below). | Upstream CodeBuild CDK template, pinned ref (`backend/deploy/`) + overlay CDK app (`backend/overlay/`) |
| **FE** (frontend) | petsite built from **unmodified upstream source**, CloudFront in front of an ALB (the ALB is not reachable directly from the internet — the canary and load generator go through CloudFront), shopper-journey canary, golden-signal alarms. | Thin CDK app (`frontend/`) that builds the upstream petsite container and wires backend URLs via PetAdoptions' native SSM parameter mechanism |

Failure mechanisms actually available on this deployment: AWS FIS `stop-task`
experiments (created by the overlay), the DynamoDB provisioned-capacity change,
the petsite autoscaling toggle, and the SQS event-source-mapping toggle. The
upstream's app-level chaos/degradation/simulator HTTP endpoints are **not present
in the container images this deployment runs** — see
[Upstream chaos endpoints: not present](#4-upstream-chaos-endpoints-not-present-in-the-deployed-images).

## Contents

| Path | Account | Purpose |
|---|---|---|
| `backend/deploy/` | BE | Wrapper for the upstream CodeBuild CDK CloudFormation template (`cfn-codebuild-stack.yaml`, upstream ref pinned to a full commit SHA, parameters from `config/accounts.json`). No application code. |
| `backend/overlay/` | BE | Thin CDK app: business SLO + infra alarms, `aiops-poc-incidents` SNS topic, `aiops-backend-domain-read` role, SSM exports `/aiops-poc/workload/*`, PrivateLink service, FIS experiment templates (`payments-crash`, `search-crash`). |
| `frontend/` | FE | CDK app: petsite service from unmodified upstream source (container build), ALB behind a CloudFront distribution (its domain is published to `/aiops-poc/workload/petsite-url`), Synthetics journey canary `aiops-poc-journey` + the three `aiops-poc-fe-golden-*` alarms, SSM parameters pointing at BE service URLs. |

## Fidelity rules

1. Upstream application code is never forked or modified — FE builds petsite
   from upstream source as-is.
2. Cross-account wiring uses the app's own SSM-parameter configuration
   mechanism.
3. Every PoC addition lives in `backend/overlay/` or the `frontend/` wrapper.
4. Any unavoidable delta from upstream is documented here with rationale.

**Known accepted delta.** The upstream template deploys the whole application as
one unit, so the BE account also runs the upstream's own petsite. In this
upstream revision that copy runs on the upstream **EKS** cluster
(`PetsiteEKS-cluster`), not as an ECS service, so the overlay's original
"scale petsite to zero" construct was **omitted** — disabling an EKS Deployment
from CDK would need kubectl/EKS access and is out of scope. The BE petsite copy
therefore keeps running and is simply unused: the demo's customer-facing site is
the FE one, and only the FE canary and `loadgen/run.sh` drive it.

---

## Upstream inventory

> Source: [aws-samples/one-observability-demo](https://github.com/aws-samples/one-observability-demo)
> at the pinned ref — `upstream.ref` in `config/accounts.json`, which defaults to
> the full commit SHA this inventory was verified against. If you move it, use a
> branch, a tag, or another **full 40-character** SHA: every consumer fetches the
> ref by name and an abbreviated SHA is not fetchable. Verified against a live
> deployment in the BE account. Account IDs, region and profile names all come from
> `config/accounts.json`; the project default region is `us-east-1`, and the
> examples below use it.

---

### 1. Petsite SSM URL parameter names

PetAdoptions uses SSM Parameter Store for service discovery between petsite
(the UI) and the backend microservices. The petsite .NET container reads these
parameters at startup to locate its dependencies.

| SSM parameter name | Points to | Used by |
|---|---|---|
| `/petstore/petsiteurl` | petsite URL (self-reference, per account) | upstream canaries |
| `/petstore/searchapiurl` | petsearch HTTP endpoint | petsite → search |
| `/petstore/paymentapiurl` | payforadoption checkout endpoint (`/api/completeadoption`) | petsite → checkout/pay |
| `/petstore/cleanupadoptionsurl` | payforadoption cleanup endpoint (`/api/cleanupadoptions`) | petsite → housekeeping |
| `/petstore/petlistadoptionsurl` | petlistadoption HTTP endpoint (`/api/adoptionlist/`) | petsite → list adoptions |
| `/petstore/petfoodapiurl` | petfood foods endpoint (`/api/foods`) | petsite → food pages |
| `/petstore/petfoodcarturl` | petfood cart endpoint (`/api/cart`) | petsite → cart |
| `/petstore/updateadoptionstatusurl` | petstatusupdater API Gateway endpoint | petsite → status update |
| `/petstore/petfoodagent-runtime-arn` | Bedrock AgentCore runtime ARN | petsite → Waggle chat |
| `/petstore/queueurl` | SQS queue URL for adoption messages | payforadoption → SQS |
| `/petstore/dynamodbtablename` | DynamoDB pets table name | petstatusupdater, petsearch, seeding |
| `/petstore/foods_table_name`, `/petstore/carts_table_name` | Petfood DynamoDB table names | petfood, seeding |
| `/petstore/rdssecretarn` | Secrets Manager ARN for Aurora credentials | payforadoption, petlistadoption |
| `/petstore/rds-writer-endpoint` | Aurora writer endpoint | payforadoption, petlistadoption, seeding |
| `/petstore/rds-reader-endpoint` | Aurora reader endpoint | read-path consumers |
| `/petstore/rds-database-name` | Aurora database name (`adoptions`) | payforadoption, petlistadoption, seeding |

**Naming convention**: all parameters live under the `/petstore/` prefix and
names are lowercase — mostly concatenated, with underscores in the petfood table
params and hyphens in the `rds-*` trio. Older upstream revisions used
`payforadoptionurl` / `sqsqueueurl` / `ecsclustername` and a single
`rdsendpoint` — the current pinned upstream uses `paymentapiurl` and `queueurl`,
splits the database connection details into `rds-writer-endpoint` /
`rds-reader-endpoint` / `rds-database-name`, and publishes **no** cluster-name
parameter. Docs or scripts referencing the old names are stale.

**Cross-account wiring**: the FE account's petsite reads the same parameter names
from its own SSM Parameter Store. `scripts/sync-outputs.sh` copies BE values into
FE verbatim — EXCEPT the six URL parameters `FrontendStack` owns and points at its
PrivateLink interface endpoint (`searchapiurl`, `petlistadoptionsurl`,
`petfoodapiurl`, `petfoodcarturl`, `cleanupadoptionsurl`, `paymentapiurl`) and the
self-referential `petsiteurl`. The full ownership contract is in
[docs/parameters.md](../docs/parameters.md).

---

### 2. Resource names and ARNs

#### ECS cluster

The upstream creates one ECS cluster named **`PetsiteECS-cluster`** (Fargate plus
EC2 capacity providers, EC2 for enhanced Container Insights). `Services` is the
name of the upstream *stack*, not the cluster — the overlay, the FIS targets and
the demo runbook all use `PetsiteECS-cluster`.

#### ECS services in `PetsiteECS-cluster` (BE)

| ECS service | Language | Notes |
|---|---|---|
| `payforadoption-go` | Go | Checkout / payments. FIS target for `payments-crash` |
| `petsearch-java` | Java (Spring Boot) | Search. FIS target for `search-crash` |
| `petlistadoption-py` | Python (FastAPI) | Adoption list |
| `petfood-rs` | Rust | Food / cart pages, reached over PrivateLink |

Those four are the complete ECS service list on this cluster. Two things that
look like they should be here and are not:

- **petsite** — the upstream copy runs on the EKS cluster `PetsiteEKS-cluster`;
  the demo's petsite runs in the **FE** account (cluster `aiops-poc-petsite`,
  service `petsite`).
- **PetFoodAgent** — runs on Bedrock AgentCore Runtime, not ECS (below).

The older upstream names `PayForAdoption` / `PetSearch` / `PetListAdoptions` do
**not** exist in this revision. Targeting them makes an FIS `aws:ecs:task`
selector match zero tasks — a silent no-op.

#### PetFood agent (Waggle AI chat)

The Waggle tab in petsite (`/Waggle?userId=...`) chats with the PetFood agent — a
Strands agent on **Bedrock AgentCore Runtime** in the BE account (ARM64 container,
built during the upstream's Containers stage but deployed to AgentCore rather than
ECS — per the upstream's
[petfoodagent-strands-py doc](https://github.com/aws-samples/one-observability-demo/blob/main/docs-site/docs/microservices/petfoodagent-strands-py.md)).
The upstream gates it behind `ENABLE_PET_FOOD_AGENT`, which our CodeBuild wrapper
(`workload/backend/deploy/cfn-codebuild-stack.yaml`) enables, deriving
`AVAILABILITY_ZONES` from the existing workshop VPC (AgentCore VPC mode is
AZ-restricted, and changing the VPC's AZ set would restructure its subnets).

Cross-account wiring (petsite runs in FE, the agent in BE):

| Piece | Where |
|---|---|
| AgentCore runtime + `/petstore/petfoodagent-runtime-arn` (BE) | upstream CDK (`ENABLE_PET_FOOD_AGENT=true`) |
| Runtime ARN synced BE → FE | `scripts/sync-outputs.sh` (`--section urls`) |
| Resource policies on runtime **and** DEFAULT endpoint (allow FE) | `BackendOverlayStack` |
| `bedrock-agentcore:InvokeAgentRuntime` on petsite task role | `FrontendStack` |

The agent invokes `us.anthropic.claude-sonnet-4-6` (cross-region inference
profile) — the BE account needs Anthropic model access enabled in Bedrock.
Graceful degradation: if the agent is not deployed, the ARN parameter never
reaches FE and petsite's Waggle controller fails fast with a friendly
"having trouble connecting" chat reply (no timeout).

#### Lambda functions

| Function (upstream role) | Purpose |
|---|---|
| petstatusupdater | Updates pet adoption status in DynamoDB; triggered by the status-update SQS queue |
| user creator | Creates user records from SQS messages |

Function names are **deployment-generated**, not the upstream logical names — the
status-update consumer is not called `StatusUpdater` in a live deployment. That is
why `chaos/scripts/inject.sh` finds its event-source mapping by resolving
`/petstore/queueurl` → queue ARN → `lambda list-event-source-mappings`, instead of
matching on a function name. Resolve names live rather than hardcoding them.

#### DynamoDB tables

| Table | Purpose | Capacity mode |
|---|---|---|
| Pet adoptions table — name resolved from `/petstore/dynamodbtablename` | Pet adoption records + status | Provisioned (key for scenario B4) |

The name is CloudFormation-generated (of the shape
`DevStorageStack-DynamoDbddbPetadoption<hash>-<suffix>` — an example, not a value
to type), so always read it from SSM. The table uses **provisioned** capacity with
Contributor Insights enabled, and the upstream adds throttle alarms on
`ReadThrottleEvents` / `WriteThrottleEvents` (threshold 0). This is the mechanism
`ddb-throttle` (B4) exploits.

#### SQS queues

| Queue (upstream role) | Purpose |
|---|---|
| status-update queue — URL from `/petstore/queueurl` | Carries adoption completion messages from payforadoption → the status-updater Lambda |
| user-creation queue | User creation requests |

Queue names are CloudFormation-generated; both have dead-letter queues. Resolve
from SSM.

#### Aurora cluster (PostgreSQL)

| Resource | Details |
|---|---|
| Cluster ID | generated with a stack suffix |
| Engine | Aurora PostgreSQL |
| Database name | `adoptions` (also published as `/petstore/rds-database-name`) |
| Access | Via Secrets Manager (`/petstore/rdssecretarn`), writer endpoint from `/petstore/rds-writer-endpoint` (reader endpoint in `/petstore/rds-reader-endpoint`) |

#### API Gateway and S3

- A REST API fronting the status-updater Lambda (URL in
  `/petstore/updateadoptionstatusurl`).
- Seed-data bucket (pet images, initial data) and a Synthetics artifacts bucket
  (screenshots and logs). Both names are generated.

---

### 3. Telemetry metric names

#### Application Signals / ADOT metrics

The upstream instruments each microservice differently; all emit into the
`ApplicationSignals` CloudWatch namespace via ADOT/OpenTelemetry:

| Metric | Namespace | Description |
|---|---|---|
| `Latency` | `ApplicationSignals` | Request latency in milliseconds |
| `Fault` | `ApplicationSignals` | Count of 5XX / span status errors |
| `Error` | `ApplicationSignals` | Count of 4XX client errors |

**Key dimensions.** An alarm must carry the **full** dimension set
`[Environment, Service]` (plus `Operation` where it filters one route), or it
matches no metric and sits in `INSUFFICIENT_DATA` forever. The emitted `Service`
value is the **OTEL** service name, which differs from the ECS service name:

| Service | `Environment` | `Service` (OTEL) | ECS service name |
|---|---|---|---|
| payforadoption | `generic:default` | `payforadoption-api-go` | `payforadoption-go` |
| petsearch | `ecs:PetsiteECS-cluster` | `petsearch-api-java` | `petsearch-java` |

The ECS names remain the correct ones for FIS targeting.

**Instrumentation strategy per service**:

| Service | Instrumentation | Collector |
|---|---|---|
| payforadoption-go | Manual OpenTelemetry Go SDK + custom SQL span processor | ADOT sidecar (OTLP → X-Ray) |
| petsearch-java | Application Signals auto-instrumentation + manual spans | CloudWatch Agent (Application Signals) |
| petlistadoption-py | ADOT Python auto-instrumentation + Prometheus metrics | ADOT sidecar |
| petsite-net | Application Signals (.NET) | CloudWatch Agent |

**Our alarms** are built on these plus ALB and Synthetics metrics. The canonical
list of all 15 alarms, their exact conditions and which five page a human, is the
[alarm inventory in deployment.md](../docs/deployment.md#alarm-inventory) — treat
that as the source of truth rather than restating thresholds here.

#### Synthetics canaries

| Canary | Account | Purpose |
|---|---|---|
| upstream traffic generator + housekeeping canaries | BE | Baseline traffic against the backend services; keeps metrics populated |
| `aiops-poc-journey` | FE | Shopper journey (home → search → adoption list → checkout), **runs every minute**, emits `SuccessPercent` / `Duration` in `CloudWatchSynthetics`. Asserts on page **content** as well as HTTP status, because petsite masks a dead backend behind a fast 200 page |

`aiops-poc-journey` is the demo's primary detector. See
[loadgen/README.md](../loadgen/README.md) for how baseline and burst traffic
combine.

---

### 4. Upstream chaos endpoints: NOT PRESENT in the deployed images

> **Status: NOT PRESENT.** The endpoint shapes below are transcribed from the
> upstream workshop documentation and kept for reference only. In the container
> images this deployment runs they return **HTTP 404** (verified with an in-VPC
> probe), and petlistadoption's OpenAPI document lists only
> `/api/adoptionlist/`, `/health/status` and `/metrics`. Do not build a demo on
> them. Full reasoning and the deferral decision:
> [docs/scenarios.md#future-enhancements](../docs/scenarios.md#future-enhancements).

Documented (absent) payforadoption chaos/degradation endpoints:

| Endpoint | Purpose | Documented effect |
|---|---|---|
| `POST /chaos/enable` | Enable chaos mode | Error injection on subsequent requests |
| `POST /chaos/disable` | Disable chaos mode | Restore normal operation |
| `GET /chaos/status` | Read chaos state | JSON `{"enabled": true/false}` |
| `POST /degradation/enable` | Enable degradation mode | Add artificial latency to payment processing |
| `POST /degradation/disable` | Disable degradation mode | Restore normal latency |
| `GET /degradation/status` | Read degradation state | JSON with current config |

Documented request body: `{"latency_ms": 3000, "error_rate": 0.0}` —
`latency_ms` is the delay added per request, `error_rate` the fraction of
requests returning HTTP 500.

Documented (absent) petlistadoption DB load simulators, which drive Aurora
contention visible in Performance Insights:

| Simulator | Documented path | Documented effect on Aurora |
|---|---|---|
| Slow query | `POST /simulate/slowquery` | Intentionally slow SQL (large scans, `pg_sleep`) appears in Performance Insights top SQL |
| Lock blocking | `POST /simulate/lockblocking` | Holds exclusive locks so later transactions wait — visible as blocking sessions |
| Deadlock | `POST /simulate/deadlock` | Circular lock dependencies generate deadlock events |
| Unique violation | `POST /simulate/uniqueviolation` | Duplicate inserts generate constraint-violation errors |

How the deferred faults would map onto them:

| Fault ID | Endpoint | Parameters | Runnable? |
|---|---|---|---|
| `checkout-degraded` (B1) | `POST /degradation/enable` on payforadoption | `{"latency_ms": 3000}` | No — endpoint absent; `inject.sh` fails fast |
| `payments-error` (B3) | `POST /chaos/enable` on payforadoption | `{"error_rate": 0.5}` | No — endpoint absent; `inject.sh` fails fast |
| `db-overload` (B1) | `POST /simulate/lockblocking` on petlistadoption | — | No — endpoint absent; `inject.sh` fails fast |

`chaos/scripts/inject.sh` keeps the injection logic for a future chaos-enabled
image but refuses these three fault IDs before making any AWS call.
`chaos/scripts/restore.sh` has **no** such guard: it will accept them and attempt
live calls that cannot succeed, so don't run restore for a fault you couldn't
inject. Service URLs would come from `/petstore/paymentapiurl` and
`/petstore/petlistadoptionsurl`, stripped to their origin — the endpoints are
served at the service root, while those parameters carry API paths.

---

### 5. Dynamo-capacity mechanism (fault `ddb-throttle`)

The adoptions table is deployed with **provisioned** capacity, which is what
makes throttling injectable.

- `chaos/scripts/inject.sh ddb-throttle` reads the table's current
  `ReadCapacityUnits` / `WriteCapacityUnits`, saves them to
  `/aiops-poc/chaos/ddb-original-*`, and updates the table to 1 RCU / 1 WCU.
- `restore.sh ddb-throttle` writes the saved values back and deletes the markers.
  The restore is clean — no forced ECS deployment needed.
- Impact path: `petsearch-java` reads the table → reads are throttled →
  search latency climbs → the FE journey canary breaches. The upstream throttle
  alarms on `ReadThrottleEvents` / `WriteThrottleEvents` fire as evidence.
- **Inject before starting load.** A table at full capacity banks up to ~300 s of
  unused throughput, so traffic started first is absorbed with no throttles.

---

### 6. Selective-stack-deploy support

#### Upstream pipeline architecture

The upstream deploys a multi-stage CDK pipeline via CodeBuild, roughly: core
networking and IAM, then data stores (Aurora, DynamoDB, SQS, S3), then compute
(ECS/EKS clusters, ALBs), then serverless (Lambda, API Gateway) and monitoring
(dashboards, alarms, canaries), with the microservices deployed as one
applications stage.

#### Can individual stacks be deployed selectively?

**Partially.** The upstream is designed as a single `cdk deploy --all` flow via
the CodeBuild template:

1. Individual stacks CAN be targeted with `cdk deploy <StackName>`, but stage
   dependencies are enforced — the applications stage needs the core, data and
   compute stacks in place.
2. **There is no "skip petsite" option.** The applications stage deploys all
   microservices together, with no CDK context flag to exclude one. This is why
   the PoC accepts the unused BE petsite copy as a delta.
3. **The CodeBuild template is the supported entry point** — it bootstraps CDK,
   runs the pipeline and handles retries. Direct `cdk deploy` is possible but
   requires manual bootstrap and dependency ordering.

#### Implications for the PoC

- **BE**: use the upstream CodeBuild template as-is (all stacks deploy), then add
  the overlay.
- **FE**: a separate CDK app builds petsite from upstream source — a parallel
  build, not a selective deploy of the upstream.
- **The BE petsite copy stays**: removing it would need upstream modifications or
  EKS-level intervention. Documented as an accepted delta above.

---

## Post-deploy verification checklist

Run these after the BE deployment completes (substitute your own profile names
from `config/accounts.json`; the project default region is `us-east-1`).

- [ ] `aws ssm get-parameters-by-path --path /petstore/ --recursive --profile backend-app --region us-east-1` — confirm the parameter names above exist
- [ ] `aws ecs list-services --cluster PetsiteECS-cluster --profile backend-app --region us-east-1` — expect exactly `payforadoption-go`, `petsearch-java`, `petlistadoption-py`, `petfood-rs`
- [ ] `aws dynamodb describe-table --table-name "$(aws ssm get-parameter --name /petstore/dynamodbtablename --query Parameter.Value --output text --profile backend-app --region us-east-1)" --profile backend-app --region us-east-1` — confirm **provisioned** capacity and record the original RCU/WCU
- [ ] `aws lambda list-event-source-mappings --event-source-arn <status-update queue ARN> --profile backend-app --region us-east-1` — confirm one enabled mapping (resolve the ARN from `/petstore/queueurl`)
- [ ] `aws fis list-experiment-templates --profile backend-app --region us-east-1` — after the overlay deploy, expect templates tagged `payments-crash` and `search-crash`
- [ ] Chaos/simulator endpoints: **expect HTTP 404.** A probe such as
      `curl -s -o /dev/null -w '%{http_code}' <payforadoption-origin>/chaos/status`
      returning 404 is the **correct, expected** result on these images — it
      confirms the three endpoint-based faults are unavailable, not that your
      deploy failed. A 200 would mean you are running a chaos-enabled image and
      could revisit the [future enhancements](../docs/scenarios.md#future-enhancements)
- [ ] CloudWatch console → Application Signals → Services — confirm the
      instrumented services appear with the OTEL names above
- [ ] CloudWatch console → Synthetics → Canaries — confirm the upstream canaries
      in BE, and `aiops-poc-journey` in FE once the frontend is deployed

## Where to go next

- [docs/parameters.md](../docs/parameters.md) — the SSM parameter ownership contract
- [docs/deployment.md](../docs/deployment.md) — deployment order, the
  [alarm inventory](../docs/deployment.md#alarm-inventory) and the dated run-logs
- [docs/scenarios.md](../docs/scenarios.md) — the incident catalog and what is
  active versus deferred
- [chaos/README.md](../chaos/README.md) — injecting and restoring faults
