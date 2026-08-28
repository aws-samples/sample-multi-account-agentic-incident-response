# loadgen — traffic generation

For the operator running this demo: how to drive shopper traffic at petsite so
an injected fault becomes a customer-visible SLO breach, and which driver to use
for which fault. The script is `run.sh`; there is nothing to deploy.

> **Compliance.** This generator sends legitimate shopper-journey traffic
> against our own application, which the
> [Amazon EC2 Testing Policy](https://aws.amazon.com/ec2/testing/) permits
> without approval. `run.sh` enforces a hard 200 req/s per-process ceiling
> (`MAX_RATE`) so it can never be repurposed for flooding (prohibited by the
> [AWS penetration-testing policy](https://aws.amazon.com/security/penetration-testing/)).
> Details: [Compliance & AWS testing policies](../chaos/README.md#compliance--aws-testing-policies).

## Two layers of traffic

**Baseline (always on).** The upstream PetAdoptions stack in the BE account
deploys its own traffic generator and Synthetics canaries, which keep backend
metrics populated. In the FE account the shopper-journey canary
`aiops-poc-journey` runs **every minute** against petsite and emits
`SuccessPercent` / `Duration` in the `CloudWatchSynthetics` namespace — those two
metrics back the `aiops-poc-fe-golden-journey-success` and
`-journey-duration` alarms, which are the demo's primary detectors. The canary
asserts on page **content** as well as HTTP status, so it catches a backend that
petsite has masked behind a friendly 200 page.

**Burst (this folder).** `run.sh` adds shopper traffic on top. Some faults are
invisible without it: a throttled DynamoDB table only throttles when someone
reads it, and a pinned autoscaling maximum only hurts when traffic arrives.
Others (`payments-crash`) need no burst at all — the once-a-minute canary
detects them on its own.

## Usage

```bash
# Search-only, low-rate driver (B4 ddb-throttle / search-crash) — defaults to 12 req/s
./run.sh --paths search --duration 1500

# Full shopper journey, saturating petsite (B5 ui-no-scale: saturation is the
# point, and it must be SUSTAINED — run two of these concurrently in separate
# terminals, or saturation stays intermittent and the golden alarms never fire)
./run.sh --rate 150 --duration 1800

# Explicit URL (example host — use your own petsite domain)
./run.sh --url https://d111111abcdef8.cloudfront.net --rate 20 --duration 300

# Same thing via env var
export PETSITE_URL=https://d111111abcdef8.cloudfront.net
./run.sh --rate 20 --duration 300

# Verbose: print every request result (curl mode)
./run.sh --rate 10 --duration 30 --verbose
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--rate <n>` | `10` (`12` with `--paths search`) | Target requests per second. Positive integer, rejected above `MAX_RATE` = 200 |
| `--duration <n>` | `60` | Run length in seconds |
| `--paths <set>` | `journey` | Route set: `journey` or `search`. Any other value is an error |
| `--url <url>` | (auto) | Petsite base URL; a trailing `/` is stripped |
| `--profile <name>` | (none) | AWS CLI profile for the SSM lookup |
| `--verbose` | off | Print each request result (curl mode only) |
| `-h`, `--help` | — | Usage summary |

`Ctrl+C` stops cleanly: the script traps SIGINT/SIGTERM and prints a summary
before exiting (the per-request summary is produced in curl mode; in `hey` mode
the aggregate is printed when the workers finish).

### Route sets (`--paths`)

| Set | Routes per iteration | Default rate | Use for |
|---|---|---|---|
| `journey` | `/` (captures the session `userId` from the 302), `/PetListAdoptions?userId=…`, the same path with `selectedPetType`/`selectedPetColor` filters, `/FoodService?userId=…&petType=…` — 4 requests | 10 req/s | Broad fan-out; drives petsite render plus backend list/search/food calls |
| `search` | `/` plus two filtered `/?userId=…&selectedPetType=…&selectedPetColor=…` — 3 requests. Deliberately excludes `/PetListAdoptions` and `/FoodService` | **12 req/s** | Dependency starvation (B4). Read pressure lands on the adoptions DynamoDB table while petsite and `petsearch-java` stay near-idle, so the fault stays attributable |

`selectedPetType` is randomized across `all|puppy|kitten|bunny` and
`selectedPetColor` across `all|brown|black|white` (the live filter options).
Petsite assigns the shopper `userId` on the homepage via a 302
(`Location: /?userId=userNNNNN`); every iteration captures it from step 1 and
carries it, because the inner pages redirect instead of rendering without it. All
requests are idempotent GETs — no pet inventory is mutated.

> **`--rate 50` is harmful — do not use it as a generic default.** Measured with
> **no fault injected**, `--rate 50` drove the petsite ALB past 2 400 req/min,
> failed the journey canary three times, and **OOM-killed the petsite web
> container** (exit 137 against the 1024 MiB limit) into a 6–7 minute crash
> loop — while producing **zero** DynamoDB throttles. `--rate 30` and `--rate 12`
> on the full journey also failed the canary. At that point you are
> investigating your own load generator. Use `--paths search` for search-path
> faults; reserve high journey rates for B5, where saturation is the intended
> mechanism. See the B4 run-logs in
> [deployment.md](../docs/deployment.md#run-log).

### Which driver for which fault

| Fault | Driver | Duration | Why |
|---|---|---|---|
| `payments-crash` (B3) | none needed | — | The once-a-minute canary fails on the checkout/housekeeping content check; extra load adds nothing |
| `ddb-throttle` (B4) | `--paths search` (~12 req/s) | 1200–1500 s | ~8–12 RCU/s against a 1 RCU table throttles within ~75 s once banked capacity drains. Inject **before** starting load. Never `--rate 30`/`50` here |
| `search-crash` (B4) | `--paths search` (~12 req/s) | ~900 s | Any search request reveals a stopped service; low rate keeps attribution clean |
| `ui-no-scale` (B5) | **two concurrent generators** (journey paths, e.g. `--rate 150` each in separate terminals — a single generator leaves saturation intermittent and the alarms never fire) | 900–1800 s | Saturating the pinned task count *is* the fault. Record autoscaling state and container exit codes separately — OOM/exit-137 churn comes from the load level, not from the pinned `MaxCapacity` |

The four [future-enhancement faults](../docs/scenarios.md#future-enhancements)
(`checkout-degraded`, `db-overload`, `payments-error`, `status-consumer-off`)
have no load recipe here: three refuse to inject, and B2's queue-age detector
is time-driven, not rate-driven.

### URL resolution (priority order)

1. `--url` argument
2. `PETSITE_URL` environment variable
3. SSM parameter `/aiops-poc/workload/petsite-url` (the FE CloudFront URL,
   published by `FrontendStack`). Needs FE credentials — pass `--profile`

If none resolves, the script exits with an error.

### Tool selection

`run.sh` auto-detects, preferring `hey`:

- **`hey`** — parallel workers with rate limiting. In `journey` mode it starts
  four workers, one per route, each at `--rate / 4` req/s (integer division, so
  the effective total rounds down). In `search` mode it starts three workers at
  `--rate / 3`, split into `-c 2 -q <n>` — the validated B4 recipe is
  3 × (`-c 2 -q 2`) ≈ 12 req/s. Install with
  `go install github.com/rakyll/hey@v0.1.5` or `brew install hey`.
- **`curl`** — sequential fallback: one iteration at a time with a sleep of
  `requests-per-iteration / rate` seconds between iterations, progress every 10
  iterations. Universally available, less precise, and capped by response time.

Request timeouts are 10 s per request, except the homepage step in `search` mode
which allows 35 s. Under heavy throttling a slow request can exceed the cap and
is counted as a failure (`000`) — expected, and itself a symptom.

## Prerequisites

- `curl` (usually pre-installed) or `hey` (preferred)
- AWS CLI, if you want SSM-based URL resolution
- Network access to the public petsite endpoint

## Troubleshooting

**"Cannot resolve petsite URL"** — set `PETSITE_URL`, pass `--url`, or supply
`--profile` for the FE account so the SSM lookup can run.

**Low actual rate in curl mode** — curl mode is sequential, so throughput is
bounded by response time. Install `hey` for rates above ~30 req/s.

**Connection refused / non-2xx everywhere** — check petsite is up:
`curl -s -o /dev/null -w '%{http_code}' "$PETSITE_URL/"`.

**Canary failing but no fault injected** — you are probably running too much
load. See the `--rate 50` warning above.
