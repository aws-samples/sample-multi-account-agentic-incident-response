# Backend Upstream Deployment

*For the technical account manager replicating this demo in their own BE / FE /
OPS accounts: after this page you can deploy the upstream PetAdoptions backend
into your BE account, seed its databases, and know exactly which resources you
should expect to find afterwards.*

Deploys the upstream [`aws-samples/one-observability-demo`](https://github.com/aws-samples/one-observability-demo) PetAdoptions backend **without forking application source code**.

## How it works

This directory contains a wrapper around the upstream deployment mechanism:

1. **`cfn-codebuild-stack.yaml`** — A CloudFormation template that provisions:
   - A CodeBuild project with a buildspec that fetches the pinned upstream ref
     and runs the upstream CDK deploy (with `ENABLE_PET_FOOD_AGENT=true`, so the
     PetFood/Waggle agent is included)
   - An IAM role with permissions needed by the upstream CDK stacks
   - The CloudWatch log group `/aws/codebuild/aiops-poc-upstream-backend` for
     build logs

2. **`deploy-upstream.sh`** — A shell script that:
   - Reads parameters from `config/accounts.json` (account ID, region, profile, upstream ref)
   - Deploys the CloudFormation stack (default name `aiops-poc-upstream-backend`)
   - Starts a CodeBuild build that runs the upstream CDK deploy
   - With `--wait`, blocks until the build finishes and then seeds Aurora (via
     the upstream `rds-seeder` Lambda) and the DynamoDB pets/petfoods tables (via
     the upstream `seed-dynamodb.sh` at the pinned ref). Without `--wait` the
     seeding is skipped, since the upstream resources may not exist yet

The upstream application is deployed exactly as documented by the workshop —
CodeBuild fetches the repo and runs `cdk deploy`. `upstream.ref` is pinned to a
full commit SHA for reproducibility. Both places that fetch upstream source (the
buildspec and `deploy-upstream.sh`'s DynamoDB seeding) fetch the ref by name
rather than `git clone --branch`, so the value may be a branch, a tag, or a full
40-character commit SHA — an **abbreviated** SHA is not fetchable and fails.

## Prerequisites

- AWS CLI v2 configured with the `backend-app` profile (or the profile name in your config)
- `jq` installed for JSON parsing
- `config/accounts.json` filled in (copy `config/accounts.json.template`)
- CDK bootstrap completed in the target account/region:
  ```bash
  cdk bootstrap aws://<BE-ACCOUNT-ID>/us-east-1 --profile backend-app
  ```
  Your BE account ID is in `config/accounts.json` (`backend.accountId`); the
  default replication region for all three accounts is `us-east-1`. That is CDK's
  default qualifier; the build bootstraps upstream's own qualifier separately, and
  the two coexist (see
  [Repo apps stop deploying after an upstream build](#repo-apps-stop-deploying-after-an-upstream-build)).

## Usage

### Deploy

```bash
# Deploy with defaults from config/accounts.json
./deploy-upstream.sh

# Deploy and wait for CodeBuild to complete (45-90 minutes), then seed the databases
./deploy-upstream.sh --wait

# Override profile or region
./deploy-upstream.sh --profile my-profile --region us-east-1
```

### Seed only

If the upstream is already deployed and you just need the pets / adoption data:

```bash
./deploy-upstream.sh --seed-only
```

Seeding is idempotent and resolves table names from the upstream SSM contract
(`/petstore/dynamodbtablename`, `/petstore/foods_table_name`,
`/petstore/carts_table_name`) rather than from hardcoded names.

### Destroy

```bash
# Remove the CodeBuild stack (does NOT remove upstream PetAdoptions resources)
./deploy-upstream.sh --destroy
```

To fully clean up the upstream PetAdoptions resources, follow the
[upstream cleanup procedure](https://aws-samples.github.io/one-observability-demo/operations/cleanup/).

## Troubleshooting

### The CodeBuild build ended `TIMED_OUT`

The upstream CDK deploy takes **over an hour** — 45–90 minutes, at the slow end
for a first deploy into a cold account. `BuildTimeoutMinutes` in
`cfn-codebuild-stack.yaml` now defaults to **120** for that reason (it was 60,
which timed out a real deployment). CodeBuild bills only the minutes a build
actually consumes, so the larger timeout costs nothing.

**If your stack already exists, editing the template is not enough.** The
CodeBuild project keeps the timeout it was created with until the stack is
updated, so re-running the build without redeploying times out again at the old
value. Either redeploy the stack:

```bash
./deploy-upstream.sh          # aws cloudformation deploy — updates TimeoutInMinutes in place
```

…or, for an immediate fix without touching CloudFormation, set it on the project
directly:

```bash
aws codebuild update-project \
  --name aiops-poc-upstream-backend \
  --timeout-in-minutes 120 \
  --profile <be.profile> --region <be.region>
```

Then start a new build (`./deploy-upstream.sh`, or `aws codebuild start-build
--project-name aiops-poc-upstream-backend`). Note that a direct `update-project`
drifts from the CloudFormation stack — the next `deploy-upstream.sh` run puts
back the value the script passes, which is 120 unless you pass
`--timeout-minutes`.

`deploy-upstream.sh` passes `BuildTimeoutMinutes` on **every** run, so the cap is
authoritative rather than inherited from the existing stack. Change it with the
flag:

```bash
./deploy-upstream.sh --timeout-minutes 180
```

Allowed range 10–2160 minutes (CodeBuild's own limits, and the template's
`MinValue`/`MaxValue`); the script validates the value locally and refuses before
deploying anything, rather than letting CloudFormation reject it half a minute in.

Why the flag and not a config field: a build timeout does not differ between
replicators — it is an operational knob with a sane default — so it belongs beside
`--stack-name` rather than in `config/accounts.json`, which is the gated
Replicator_Input surface.

**Why passing it matters at all.** `aws cloudformation deploy` sends
`UsePreviousValue` for every parameter absent from `--parameter-overrides`. A
stack first created with a 60-minute cap therefore kept 60 forever, and raising
the template's default was a silent no-op on the re-run — the exact run that
needed it, having just been timed out.

### `DevMicroservicesStack` sits waiting, then fails

Not an ECS problem. The upstream ECS services pull their image by ECR URI
(untagged, so `:latest`), and the only thing that pushes that tag is the container
pipeline the upstream CDK creates in the BE account,
`DevApplicationsStack-pipeline`. A microservices stack that waits and then fails
means an image build failed.

`deploy-upstream.sh` checks for this after the CodeBuild step, on both the success
and the failure path: it derives the expected repositories from that pipeline's own
Build-stage actions and, when one has no image, prints the empty repository, the
failed action and the retry command. The check is read-only and warns rather than
failing the deploy — the broken build belongs to upstream's pipeline, not to this
wrapper. To look yourself:

```bash
aws codepipeline get-pipeline-state \
  --name DevApplicationsStack-pipeline \
  --profile <be.profile> --region <be.region>
```

Seen in practice: `Build-payforadoption-go` lost twice to a transient HTTP 502
from `gopkg.in`, because upstream's Dockerfile sets `GOPROXY=direct` — module
resolution has no proxy cache and no fallback. The image is built by upstream's
pipeline from upstream's Dockerfile and this wrapper passes both through
unmodified, so the fix is a manual stage retry (upstream's stage already retried
once by itself), with a local `docker buildx` push as the escape hatch. Commands
and the full explanation are in
[docs/deployment.md](../../../docs/deployment.md#troubleshooting-devmicroservicesstack-sits-waiting-then-fails).

### Repo apps stop deploying after an upstream build

Symptom: any of this repo's four CDK apps fails with a missing
`/cdk-bootstrap/hnb659fds/version` parameter, or on an absent
`cdk-hnb659fds-deploy-role-*`, and the BE account's IAM roles are now named
`cdk-petsite-*`.

Cause: upstream's `src/cdk/cdk.json` sets its own bootstrap qualifier
(`petsite`), and this buildspec runs CDK from that directory. A bare
`cdk bootstrap` there uses upstream's qualifier but the **default** stack name, so
it updates the `CDKToolkit` stack `scripts/bootstrap.sh` created and swaps its
staging roles out from under every other app.

The buildspec now bootstraps upstream's qualifier into its own toolkit stack
(`CDKToolkitPetsite`, matching upstream's own
`src/cdk/scripts/bootstrap-account.sh`), reads that qualifier out of upstream's
`cdk.json` rather than assuming it, and fails the build instead of swallowing a
bootstrap error. **Two toolkit stacks in the BE account — `CDKToolkit` for this
repo and `CDKToolkitPetsite` for upstream — is the correct end state**, not
something to clean up. Recovery commands and the full mechanism:
[docs/deployment.md](../../../docs/deployment.md#troubleshooting-two-cdk-toolkit-stacks-in-one-account).

## Configuration

All parameters are sourced from `config/accounts.json` — account IDs, regions and
profile names are never hardcoded in this repo:

| Field | Description |
|-------|-------------|
| `backend.accountId` | Target AWS account for the backend workload |
| `backend.region` | Target region (`us-east-1` for a default replication) |
| `backend.profile` | AWS CLI profile name (`backend-app`) |
| `upstream.org` | GitHub organization (default: `aws-samples`) |
| `upstream.repo` | Repository name (default: `one-observability-demo`) |
| `upstream.ref` | Git ref to pin: a branch, a tag, or a **full 40-character** commit SHA. Defaults to the full SHA this demo was validated against; an abbreviated SHA does not work |

## Upstream fidelity

The backend deploys through the upstream CodeBuild CDK mechanism at a pinned ref,
with no fork of the application source. All PoC-specific additions (alarms, the
incidents SNS topic, the backend domain read role, SSM exports, PrivateLink, FIS
templates) live separately in `workload/backend/overlay/`. Accepted deltas from
upstream are documented in [workload/README.md](../../README.md).

## What gets deployed

The upstream PetAdoptions backend runs its microservices in one ECS cluster,
**`PetsiteECS-cluster`** (`Services` is the name of an upstream *stack*, not the
cluster):

| ECS service | Language | Role |
|---|---|---|
| `payforadoption-go` | Go | Checkout / payments |
| `petsearch-java` | Java | Pet search (queries DynamoDB) |
| `petlistadoption-py` | Python | List adopted pets |
| `petfood-rs` | Rust | Food and cart pages |

Plus:

- **petstatusupdater** — SQS-driven status updates (Lambda; the physical function
  name is deployment-generated, so resolve it from the queue's event source
  mapping rather than by name)
- **PetFood agent** — Strands agent on Bedrock AgentCore Runtime (not ECS),
  backing the Waggle chat tab; its runtime ARN is published to
  `/petstore/petfoodagent-runtime-arn`
- **Aurora PostgreSQL** — adoption database
- **DynamoDB** — pet inventory plus the petfood foods/carts tables (all
  CloudFormation-generated names; read them from `/petstore/*`)
- **SQS queues** — async processing (`/petstore/queueurl`)
- **Traffic generator** — built-in load generation
- **petsite** — the upstream's own copy of the customer-facing UI. In the pinned
  upstream revision it runs on the **EKS** cluster `PetsiteEKS-cluster` and is
  simply **unused** by this demo; the overlay does not scale it to zero
  (disabling an EKS Deployment from CDK needs kubectl/EKS access — see the
  accepted delta in [workload/README.md](../../README.md)). The demo's
  customer-facing site is the FE copy: ECS cluster `aiops-poc-petsite`, service
  `petsite`, ALB behind CloudFront, built from unmodified upstream source by
  `workload/frontend`.

Service discovery between petsite and these services uses the upstream's own
`/petstore/*` SSM parameters — the full inventory and the BE → FE ownership
contract are in [workload/README.md](../../README.md) and
[docs/parameters.md](../../../docs/parameters.md).
