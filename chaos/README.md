# chaos — incident injection

For the operator running this demo: how to break PetAdoptions on purpose, how to
put it back, and which faults are runnable on the deployment as it ships. The
business-level story behind each fault is in
[docs/scenarios.md](../docs/scenarios.md); the dated evidence is in the
[deployment.md run-log](../docs/deployment.md#run-log).

**Fidelity rule**: reuse the upstream failure mechanisms wherever they exist —
custom mechanisms are limited to FIS experiments and configuration toggles.

## Contents

| Path | Purpose |
|---|---|
| `scripts/inject.sh <fault-id> --confirm` | Applies one fault (resources resolved from `/petstore/*` and `/aiops-poc/workload/*` SSM). Records the fault in `/aiops-poc/active-scenario`. Prints the restore command. **Requires `--confirm`** — every fault causes real customer-visible impact, so injection refuses to run without it. Refuses if another fault is active (use `--force` to override). Refuses the three future-enhancement faults outright. |
| `scripts/restore.sh <fault-id>` | Reverts the fault idempotently, clears the marker. Safe to call even if the fault isn't active. |
| `scripts/trigger-alarm.sh [<alarm>]` | **Emergency demo lever**: forces a paging alarm into ALARM via `aws cloudwatch set-alarm-state` — fires the incident chain (SNS → webhook bridge → investigation) without injecting a real fault. `--list` enumerates the **five** alarms that page. Transient by design: CloudWatch flips the alarm back to OK on the next evaluation period, no restore needed. The investigation finds no real fault evidence — this demonstrates the trigger flow only; it does NOT record `/aiops-poc/active-scenario`. |
| `fis/`, `db-load/` | Empty placeholders (`.gitkeep` only). The two FIS experiment templates are **not** files here — they are defined in CDK in `workload/backend/overlay/lib/backend-overlay-stack.ts` (`FisPaymentsCrash`, `FisSearchCrash`) and created when you deploy the backend overlay. |

All three scripts take `--profile <name>` and `--region <region>`, and all read
the default region from `config/accounts.json` (`.ops.region`), falling back to
`us-east-1`. `inject.sh` and `restore.sh` default to the `backend-app` profile,
except for `ui-no-scale` which defaults to `frontend-app`; `trigger-alarm.sh`
looks for the alarm in the BE account first and then FE unless you pass
`--profile`.

## Runnable faults

Four faults inject on this deployment as-is. Status labels match
[docs/scenarios.md](../docs/scenarios.md).

| Fault id | Incident | Mechanism | Account | Status |
|---|---|---|---|---|
| `payments-crash` | B3 — adoptions fail at checkout | FIS `aws:ecs:stop-task` (`selectionMode: ALL`) on the `payforadoption-go` ECS service | BE | validated end-to-end |
| `ddb-throttle` | B4 — search degraded (grey failure) | Reduce the adoptions DynamoDB table (`/petstore/dynamodbtablename`) to 1 RCU / 1 WCU; originals saved to SSM | BE | validated end-to-end |
| `search-crash` | B4 — search degraded (hard failure) | FIS `aws:ecs:stop-task` on the `petsearch-java` ECS service | BE | validated end-to-end |
| `ui-no-scale` | B5 — whole site slow under load | Pin the petsite Application Auto Scaling `MaxCapacity` to the service's current desired count | FE | partial (chain proven; a full load-driven run to local-only diagnosis is outstanding) |

### Usage

```bash
# List the alarms that PAGE (both workload accounts), then force one to ALARM.
# Trigger flow only — no real fault, auto-reverts, the investigation finds nothing.
./chaos/scripts/trigger-alarm.sh --list
./chaos/scripts/trigger-alarm.sh aiops-poc-fe-golden-journey-success

# B3 — payments crash (BE). No extra load needed: the once-a-minute canary sees it.
./chaos/scripts/inject.sh payments-crash --confirm
./chaos/scripts/restore.sh payments-crash

# B4 — DynamoDB throttling (BE). Inject FIRST, then drive search-only traffic.
./chaos/scripts/inject.sh ddb-throttle --confirm
./loadgen/run.sh --paths search --duration 1500
./chaos/scripts/restore.sh ddb-throttle

# B4 — search crash (BE)
./chaos/scripts/inject.sh search-crash --confirm
./loadgen/run.sh --paths search --duration 900
./chaos/scripts/restore.sh search-crash

# B5 — petsite cannot scale (FE account). Saturation IS the mechanism here, and
# it must be SUSTAINED: a single generator leaves it intermittent and the alarms
# never fire — run TWO concurrent generators (separate terminals; this is the
# validated recipe, see docs/scenarios.md#b5--site-slow-under-load):
./chaos/scripts/inject.sh ui-no-scale --confirm
./loadgen/run.sh --rate 150 --duration 1800    # terminal 1
./loadgen/run.sh --rate 150 --duration 1800    # terminal 2, concurrently
./chaos/scripts/restore.sh ui-no-scale

# Override profile/region; force past an active fault marker
./chaos/scripts/inject.sh ddb-throttle --confirm --profile my-be-profile --region us-west-2
./chaos/scripts/inject.sh search-crash --confirm --force
```

Load-generator guidance per fault (including why `--rate 50` is the wrong tool
for B4) lives in [loadgen/README.md](../loadgen/README.md).

### Operational wrinkles worth knowing

- **Inject before starting load.** A full-capacity DynamoDB table banks roughly
  300 s of unused capacity, so load started before `ddb-throttle` is absorbed
  with no throttles and the evidence window is polluted.
- **Crash faults need a re-kill cadence.** Both FIS templates run
  `aws:ecs:stop-task` once. ECS restarts the tasks within a minute, which is
  long enough for the canary to pass again, so keep tasks down with a ≤20 s
  re-kill loop for the length of the run (there is a ready-made loop in
  [deployment.md](../docs/deployment.md#run-the-demo)).
- **Crash-fault restore usually needs a nudge.** After a re-kill loop the ECS
  service typically sits in start-failure backoff. `restore.sh` stops the FIS
  experiment; clearing the backoff needs
  `aws ecs update-service --cluster PetsiteECS-cluster --service <svc> --force-new-deployment`.
  `ddb-throttle` restore is clean — it kills no tasks and needs no forced
  deployment.
- **One fault at a time.** `inject.sh` refuses when
  `/aiops-poc/active-scenario` is set to anything but `none`. Restore first, or
  pass `--force`.
- **`restore.sh` has no future-enhancement guard.** Unlike `inject.sh`, it will
  happily accept `checkout-degraded`, `payments-error` or `db-overload` and
  attempt live calls against endpoints that don't exist — the resulting output
  ("SKIP", or a `curl` warning) looks like a restore, but there was never
  anything to restore. Don't run restore for faults you couldn't inject.

## Future-enhancement faults (not runnable here)

Four more faults are documented and wired, and deferred as a roadmap item. Keep
them out of a live demo. Full reasoning:
[docs/scenarios.md#future-enhancements](../docs/scenarios.md#future-enhancements).

| Fault id | Incident | Mechanism (as designed) | Why it can't run |
|---|---|---|---|
| `checkout-degraded` | B1 | `POST /degradation/enable` on payforadoption, latency mode | Endpoint absent from the deployed image (HTTP 404) — `inject.sh` fails fast |
| `db-overload` | B1 | `POST /simulate/lockblocking` on petlistadoption (Aurora lock contention) | Endpoint absent from the deployed image (HTTP 404) — `inject.sh` fails fast |
| `payments-error` | B3 | `POST /chaos/enable` on payforadoption, error mode | Endpoint absent from the deployed image (HTTP 404) — `inject.sh` fails fast |
| `status-consumer-off` | B2 | `lambda update-event-source-mapping --no-enabled` on the mapping consuming `/petstore/queueurl` (resolved by queue ARN, not by function name) | **Injects and restores cleanly**, but the deployed upstream's adoption path never publishes status messages, so the queue never ages and `aiops-poc-be-slo-statusupdate-lag` can never fire |

For the first three, `inject.sh` exits non-zero with a message pointing at
`docs/scenarios.md#future-enhancements` before making any AWS call. The
injection logic stays in the script for a future chaos-enabled upstream image.
`status-consumer-off` is not guarded — it will inject; it just can't produce an
incident. Use `trigger-alarm.sh aiops-poc-be-slo-statusupdate-lag` if you want
to show B2's trigger chain.

## State management

- **Active scenario marker**: `/aiops-poc/active-scenario` in BE account SSM.
  No stack creates it: `inject.sh` writes it on the first injection and
  `restore.sh` sets it back to `none`, so on a freshly deployed estate reading
  it returns `ParameterNotFound` — equivalent to `none`.
- **Original values** (written by inject, read and deleted by restore):
  - `/aiops-poc/chaos/ddb-original-rcu` — DynamoDB original read capacity
  - `/aiops-poc/chaos/ddb-original-wcu` — DynamoDB original write capacity
  - `/aiops-poc/chaos/ddb-table-name` — DynamoDB table name
  - `/aiops-poc/chaos/ui-original-max-capacity` — petsite original autoscaling max
  - `/aiops-poc/chaos/payments-crash-experiment` — FIS experiment ID
  - `/aiops-poc/chaos/search-crash-experiment` — FIS experiment ID
  - `/aiops-poc/chaos/status-updater-esm-uuid` — Lambda event source mapping UUID

Markers always live in the **BE** account, including for the FE-targeted
`ui-no-scale` fault. All faults are reversible with no data loss. The agents
must never read `/aiops-poc/active-scenario` — it exists only for demo
bookkeeping.

## Which alarms page

`trigger-alarm.sh --list` filters on alarms named `aiops-poc*` that have an SNS
action pointing at an incidents topic. That is exactly **five** of the 15
alarms:

- `aiops-poc-fe-golden-journey-success`, `-journey-duration`,
  `-checkout-error-rate` (FE) → **app-team** space
- `aiops-poc-be-slo-statusupdate-lag` (BE) → **app-team** space
- `aiops-poc-be-infra-payments-tasks` (BE) → **platform** space — the dual path;
  the OPS webhook bridge routes on the `aiops-poc-be-infra-*` prefix

The other ten (`aiops-poc-be-slo-*` except `-statusupdate-lag`, and the rest of
`aiops-poc-be-infra-*`) are deliberately actionless evidence: forcing them into
ALARM fires nothing. Their absence from `--list` is intended, not a missing
deploy. Full conditions:
[alarm inventory](../docs/deployment.md#alarm-inventory).

## Compliance & AWS testing policies

Everything this PoC does for load generation and fault injection stays inside
AWS's published testing policies:

- **[Amazon EC2 Testing Policy](https://aws.amazon.com/ec2/testing/)** —
  network stress tests that send legitimate traffic a target is expected to
  handle are permitted without prior AWS approval; AWS traffic-shaping
  considerations begin at tens of Gbps. `loadgen/run.sh` drives realistic
  shopper-journey traffic (browse → search → view → adopt) against **our own
  application** at 10–12 req/s by default, and at most a low-hundreds req/s in
  the heaviest recorded run — orders of magnitude below any threshold.

- **[AWS Customer Support Policy for Penetration Testing](https://aws.amazon.com/security/penetration-testing/)** —
  DDoS, simulated DoS, and request/port/protocol flooding are **prohibited**.
  The load generator must never be repurposed for flooding; `loadgen/run.sh`
  enforces a hard per-process rate ceiling (`MAX_RATE`, 200 req/s) and refuses
  to run above it.

- **Chaos mechanisms are all sanctioned or self-contained**:
  - AWS FIS is the AWS-native, sanctioned fault-injection service
    (`payments-crash`, `search-crash`).
  - `ddb-throttle` and `ui-no-scale` are reversible configuration changes on
    resources in **our own accounts**.
  - The deferred app-level faults (`checkout-degraded`, `payments-error`,
    `db-overload`) would use chaos endpoints built into the upstream
    aws-samples PetAdoptions application itself.

  Nothing targets AWS infrastructure, other tenants' resources, or services
  outside these accounts.

- **`cloudwatch set-alarm-state`** (used by `scripts/trigger-alarm.sh`) is a
  documented CloudWatch testing API for temporarily setting alarm state.

- **Account scope**: all three accounts (BE, FE, OPS) are demo/sandbox
  accounts. No production traffic or customer data is involved.
