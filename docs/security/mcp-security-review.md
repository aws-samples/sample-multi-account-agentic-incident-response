# MCP Security Review — backend-diagnostics

*For the technical account manager replicating this demo: this is the
indirect-prompt-injection review the custom MCP server needs before it can be
registered as a capability provider in an Agent Space. Read it to understand
what the gate checks, then re-run the review against your own copy of the
package with the command below.*

| | |
|---|---|
| **Date** | 2026-07-20 |
| **Skill** | `AIDevOpsAgentMCPSecurityReview` (agent `devops-agent-custom-mcp-security`), installed from version set `AIDevOpsAgentMCPSecurityReview/development` via `aim agents install` (aim 1.0.4129.0) |
| **Target package** | `mcp-servers/backend-diagnostics` (`backend-diagnostics-mcp` 0.1.0) |
| **Call chain reviewed** | `src/__main__.py` → `src/server.py` (FastMCP, 7 tools, streamable HTTP) → `src/tools/{service_health,lambda_stats,queue_stats,dynamodb_health,db_health,canary_results,recent_alarms}.py` → `src/aws_client.py` (STS AssumeRole into a single deploy-time-fixed BE read role → boto3 read-only APIs) → `src/config.py`. No local SDK/shared packages in the path; third-party deps: `mcp`, `boto3`/`botocore`, `uvicorn`, `starlette`. Nothing UNVERIFIED. |
| **Result** | **PASS** |
| **Raw session log** | `docs/security/mcp-security-review-session.log` |

Scope note: this skill only checks indirect-prompt-injection risk (mutating
actions and attacker-directable outbound calls) for custom MCP tools used
with the AWS DevOps Agent. It is not a full security review.

> **Addendum (2026-07-23), outside review scope:** the backend-kb-agent —
> which is **not** part of the MCP server reviewed above — gained a single
> write-scope action: `sns:Publish` scoped to only the
> `aiops-poc-escalations` topic ARN, used by its `escalate_to_owner_team`
> tool for human escalation (email to the owning team). No workload
> mutation is possible through it; the review findings above are unchanged.
> Update (2026-07): both fallback agents were subsequently descoped to
> knowledge-only — their live AWS telemetry tools and the cross-account BE
> read grant were removed entirely, strictly improving the posture.

To regenerate:

```bash
toolbox install aim   # add --force if a completions-file conflict is reported
aim agents install AIDevOpsAgentMCPSecurityReview --version-set AIDevOpsAgentMCPSecurityReview/development
kiro-cli chat --agent devops-agent-custom-mcp-security --no-interactive --trust-all-tools \
  "Review the MCP at <repo>/mcp-servers/backend-diagnostics. Include the full call chain: <paths above>." \
  2>&1 | tee docs/security/mcp-security-review-session.log
```

The BE account ID and the ARN built from it are written below as
`<BE_ACCOUNT_ID>` — look your own value up in the git-ignored
`config/accounts.json` (`backend.accountId`). At deploy time `AgentsInfraStack`
injects it into the MCP runtime as the `BE_ACCOUNT_ID` environment variable, so
nothing in the repo needs a literal. Region resolves the same way from the
runtime environment, falling back to `us-east-1`.

---

## Backend Diagnostics MCP — PASS

### Call chain verified

`__main__.py` → `server.py` (FastMCP, 7 `@mcp.tool()` registrations, stateless streamable HTTP on `0.0.0.0:8000/mcp`) → `tools/*.py` → `aws_client.py` (`get_client` → `get_be_session` → `sts.assume_role`) → `config.py` (account/role/region from the runtime environment, plus module-level resource-name constants). No SDK or shared packages in the path; third-party deps are `mcp`, `boto3`/`botocore`, `uvicorn`, `starlette`. Call chain fully traced end-to-end — nothing UNVERIFIED.

### Tools

| Tool | Parameters | Read/Write | Underlying AWS calls | Outbound Call Destination | Audit Log Exposure |
|------|-----------|------------|----------------------|--------------------------|-------------------|
| `tool_get_service_health` | `service_name: str\|None` | Read | `ecs.describe_services` | Fixed BE account (`<BE_ACCOUNT_ID>`) via the single deploy-time-fixed role | BE account (own) CloudTrail only |
| `tool_get_lambda_stats` | `minutes: int` | Read | `lambda.list_functions`, `cloudwatch.get_metric_statistics` | Fixed BE account | BE account only |
| `tool_get_queue_stats` | none | Read | `sqs.get_queue_attributes`, `cloudwatch.get_metric_statistics` | Fixed BE account (queue URL built from the configured account ID and region) | BE account only |
| `tool_get_dynamodb_health` | `table_name: str\|None` | Read | `dynamodb.describe_table`, `cloudwatch.get_metric_statistics` | Fixed BE account | BE account only |
| `tool_get_db_health` | none | Read | `rds.describe_db_clusters`, `cloudwatch.get_metric_statistics` | Fixed BE account | BE account only |
| `tool_get_canary_results` | `canary_name: str\|None` | Read | `synthetics.get_canary`, `get_canary_runs` | Fixed BE account | BE account only |
| `tool_get_recent_alarms` | `minutes: int` | Read | `cloudwatch.describe_alarms`, `describe_alarm_history` | Fixed BE account | BE account only |

### Principle 1: Mutating Actions

**No violations.** Every underlying API call is read-only (`Describe*`/`Get*`/`List*`). No tool creates, updates, deletes, scales, deploys, sends messages, writes files, or executes freeform SQL/shell. There are no freeform input parameters — inputs are limited to optional resource-name strings and integer lookback windows. None of these can trigger a state change in the underlying services.

### Principle 2: External Resource Interaction

**No violations.** The destination account is **fixed and non-caller-controllable**:

- `config.py` resolves `BE_ACCOUNT_ID` from the runtime environment (injected by `AgentsInfraStack` from `config/accounts.json`) and derives `BE_READ_ROLE_ARN` from it. Both are fixed at deploy time and unreachable from tool input.
- `aws_client.get_be_session()` always assumes that single role ARN; no tool parameter reaches `RoleArn`, the region, an endpoint, a URL, or a hostname.
- `get_queue_stats` constructs the queue URL from the configured account ID and region — no caller input.
- No parameter contains an account ID, ARN, hostname, IP, or URL. There is no way for a caller to redirect any call to an external account or attacker-controlled infrastructure.

**Category 3 (audit-log exfiltration):** The caller-influenced parameters (`service_name`, `table_name`, `canary_name`) do land in AWS API request parameters and therefore in CloudTrail — but only in the **BE account's own CloudTrail**, which is the agent's own workspace-associated backend account, not an attacker-readable account. Because the account boundary is fixed by the deploy-time role ARN, there is no cross-account call whose parameters would surface in a third party's audit trail. No exfiltration channel exists.

### Association Validation

The account/role boundary is enforced structurally (a single role ARN fixed at deploy time, not derived from input), which is the strongest form of the required mitigation — the tool physically cannot operate outside the BE workspace account.

Resource-name parameters (`service_name`, `table_name`, `canary_name`) are **not** validated against the `ECS_SERVICES` / `DYNAMODB_TABLES` / `CANARY_NAMES` allowlists in `config.py`; an arbitrary string is passed straight to the `Describe`/`Get` call. This does **not** breach either principle: the call is read-only and confined to the fixed workspace account, so an unknown name yields only a within-account describe (or a handled error). It is a minor hardening gap, not a finding.

### Findings

No security findings against the two fundamental principles. One low-severity hardening observation:

- **LOW / hardening only:** `service_name`, `table_name`, and `canary_name` bypass the existing config allowlists and are forwarded verbatim to AWS Describe/Get calls. No mutation or exfiltration risk (fixed read-only account boundary), but constraining them removes needless within-account probing surface.

### Recommended Mitigations

- (Optional hardening) Validate `service_name` against `ECS_SERVICES`, `table_name` against `DYNAMODB_TABLES`, and `canary_name` against `CANARY_NAMES`, rejecting values not in the configured allowlists. This makes the workspace-association guarantee explicit at the resource level in addition to the account level.

  **Refresh the allowlists first** — the constants in `config.py` still hold the pre-inventory placeholder names (`ECS_CLUSTER = "PetAdoptions"`, services `petsearch` / `payforadoption` / …). The deployed upstream uses cluster `PetsiteECS-cluster` with services `payforadoption-go`, `petsearch-java`, `petlistadoption-py`, `petfood-rs`. Enforcing today's values would reject every real resource name. This is a code change, outside the review's scope, and it does not affect the PASS result.

### Final Score: PASS

All seven tools are read-only, assume a single read-only role fixed at deploy time into one backend account, and expose no parameter that can influence the call destination or place data in an attacker-readable audit log. No mutating actions, no attacker-directable outbound calls, no exfiltration channels, and no freeform command/SQL input. Safe to proceed with MCP integration. The only recommendation is optional resource-name allowlisting as defense-in-depth.
