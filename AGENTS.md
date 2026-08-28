# AGENTS.md — AI-agent ground rules for this repository

Instructions for AI coding agents (Kiro, Claude, Amazon Q, Cursor, …) working
in this repository, and for the humans pairing with them. The human-facing
runbook is [docs/deployment.md](docs/deployment.md); this file is the contract
that lets an agent drive it safely.

## Ground rules

1. **`config/accounts.json` is the only place account-specific values live.**
   It is git-ignored. Never hardcode or commit an account ID, region, profile
   name, email, or generated resource name — in code, docs, or commit messages.
   `scripts/scan-secrets.sh` and `scripts/check-parameters.sh` enforce this;
   run both before proposing any commit.
2. **Always pass `--profile` explicitly** on AWS CLI / CDK commands (in boto3,
   `boto3.Session(profile_name=…)`). Profile names come from
   `config/accounts.json` (`backend.profile`, `frontend.profile`,
   `ops.profile`). Never rely on the default profile.
3. **One region for all three accounts** (`ops.region`, default `us-east-1`).
   The demo is not validated split across regions.
4. **Verify credentials before long operations**:
   `aws sts get-caller-identity --profile <name>` for each of the three
   profiles. The upstream deploy alone runs 45–90 minutes; the first CDK synth
   of the BE and FE apps performs live lookups, so credentials must be valid at
   synth time, not just at deploy time.
5. **Start Docker before `deploy-all.sh`.** Steps 3 and 4 build container
   images locally. `preflight.sh` check P7 reports an unreachable daemon in a
   second; without it the failure surfaces at step 3, after step 1's 45–90
   minute upstream deploy.

## Canonical deployment path

Follow the [README “Get started”](README.md#get-started) sequence, which
matches [docs/deployment.md → Reproduce this demo from scratch](docs/deployment.md#reproduce-this-demo-from-scratch):

```
scripts/setup-config.sh          # or --non-interactive --set <path>=<value> / AIOPS_* env vars
npm ci                           # in each of the four CDK app dirs
scripts/preflight.sh             # read-only gate — run before anything mutating
scripts/bootstrap.sh             # CDK bootstrap, all three accounts
scripts/deploy-all.sh            # ordered deploy, steps 1–10, stops on first error
scripts/register-webhook.sh --space app-team
scripts/register-webhook.sh --space platform
scripts/register-platform-space-mcp.sh
scripts/register-fallback-agents-mcp.sh --peer both
scripts/upload-skills.sh         # packaged by deploy-all step 9; scripts/package-skills.sh re-creates
scripts/smoke-test.sh            # gate: webhook → investigation, end to end
```

`scripts/deploy-all.sh` is the tested path — prefer it over the manual
per-stack commands. It is resumable with `--start-from N` (1–10) and supports
`--skip-upstream` when the upstream workload already exists.

## Steps only the human can do (console)

The complete list is
[docs/deployment.md → 5. Manual steps checklist (not scripted)](docs/deployment.md#5-manual-steps-checklist-not-scripted).
An agent must surface these to the human and wait — there is no API path:

- **Bedrock model access** (OPS + BE accounts) — request it **before**
  `deploy-all.sh`, or KB ingestion and the fallback agents fail.
- **Escalation-email subscription confirmation** (one-time click).
- **Operator Web App federation identifier**, set per space in the console.
- **Per-skill Active/Inactive toggle** (the skills before/after axis).
- **MCP third-party access** account setting, if the MCP registration scripts
  exit 2 (they print pre-filled console steps when gated).

## Exit-code conventions

| Code | Meaning | Examples |
|---|---|---|
| 0 | pass / done | `preflight.sh` “PASS”, `smoke-test.sh` all OK |
| 1 | fail — read the printed reason | `preflight.sh` blocking problem, `check-parameters.sh` FAILURE |
| 2 | gated or inconclusive, not broken | MCP registration blocked by an account gate (pre-filled console steps are printed), `test-fallback.sh` INCONCLUSIVE |
| 99 | refused to touch a foreign resource | `bootstrap.sh` / `destroy-all.sh` CDK-toolkit guardrails |

Gate on the verdict lines (`preflight: PASS`, `check-parameters: PASS — C1-C6
hold`, `scan-secrets: clean`) as well as the exit code.

## Danger zone — explicit human confirmation required

- `scripts/destroy-all.sh --confirm` — tears down all three accounts (~1–2 h).
  Refuses without the flag. Never run it on the agent’s own initiative.
- `chaos/scripts/inject.sh <fault> --confirm` — injects a **real,
  customer-visible fault** (FIS task-stop, DynamoDB capacity cut, autoscaling
  pin). Refuses without `--confirm`; refuses when another fault is active
  (override: `--force`). Ask the human before injecting, and always plan the
  matching `chaos/scripts/restore.sh <fault>` (idempotent, never gated).
- `chaos/scripts/trigger-alarm.sh` is the safe alternative: it forces a paging
  alarm via the documented CloudWatch testing API, auto-reverts, and injects no
  fault.
- Respect the demo pre-flight rules in
  [docs/deployment.md → Run the demo](docs/deployment.md#run-the-demo): all
  alarms OK first, no stale investigations, quiet window before `ddb-throttle`,
  and never `loadgen/run.sh --rate 50` for B4.

## Verification loop

After any change: `scripts/preflight.sh --strict` (includes the parameter
contract and repo-hygiene scans), the affected `npm test` /
`python3 -m pytest scripts/tests/`, and `scripts/smoke-test.sh --managed-only`
against a live deployment. Historical run-logs in `docs/deployment.md` are
records — never rewrite them to match new behaviour.
