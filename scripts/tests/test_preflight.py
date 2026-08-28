"""Tests for scripts/preflight.sh — the Preflight_Command (task 8.2).

Every case runs the real script against a throwaway repository containing the
real Config_Resolver and the real parameter template, with the two delegates
(check-parameters.sh, scan-secrets.sh) replaced by stubs so that each test
exercises one preflight behaviour rather than the whole repository's state.

Every run happens with a stub ``aws`` first on PATH that records its invocations
to a file. The assertion that no *API* call is recorded is how Requirement 9.2's
"no AWS calls" is verified rather than assumed. Check P6 does invoke the CLI, but
only in the two modes that resolve the local service model without contacting
AWS (``--version`` and ``--generate-cli-skeleton``); those are filtered out of
the recorded log by :func:`api_calls` and asserted on their own in
``test_preflight_only_invokes_the_cli_offline``.

No 12-digit literal appears in this file: identifiers come from
``fake_account_id`` / ``placeholder_id`` in conftest (Requirement 6.5).

Validates: Requirements 9.1, 9.2, 9.3, 9.4, 7.4
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

from .conftest import BASH, REPO_ROOT, fake_account_id, placeholder_id

PREFLIGHT = REPO_ROOT / "scripts" / "preflight.sh"

STUB_PASS = "#!/usr/bin/env bash\nexit 0\n"  # nosec B105  # stub shell script body, not a credential

# ─── aws stubs for P6 ────────────────────────────────────────────────────────
#
# P6 probes the local CLI with `--generate-cli-skeleton`, which resolves the
# service model on disk and returns without calling AWS. The stubs below record
# every invocation and then answer the way a CLI of the named vintage would.
AWS_RECORD = '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "${AWS_CALL_LOG}"\n'
AWS_VERSION = 'if [[ "$1" == "--version" ]]; then printf "%s\\n" "aws-cli/{v} test"; exit 0; fi\n'

# A CLI new enough to carry devops-agent and its Asset APIs (2.34.64+).
AWS_STUB_MODERN = AWS_RECORD + AWS_VERSION.format(v="2.34.64") + "exit 0\n"

# 2.34.20–2.34.63: the namespace is there, the Asset APIs are not.
AWS_STUB_NO_ASSET_APIS = (
    AWS_RECORD
    + AWS_VERSION.format(v="2.34.48")
    + 'if [[ "$1" == "devops-agent" && "$2" == "create-asset" ]]; then exit 252; fi\n'
    + "exit 0\n"
)

# Older than 2.34.20, or any CLI without the service model: no namespace at all.
AWS_STUB_NO_NAMESPACE = (
    AWS_RECORD
    + AWS_VERSION.format(v="2.30.0")
    + 'if [[ "$1" == "devops-agent" ]]; then exit 252; fi\n'
    + "exit 0\n"
)

# The invocation modes that stay on this machine. Anything else the stub records
# would have left it, which is what Requirement 9.2 forbids.
OFFLINE_AWS_MODES = ("--version", "--generate-cli-skeleton")

DEVOPS_AGENT_DOC_ANCHOR = "docs/deployment.md#the-aws-devops-agent-cli-namespace"

# The declared paths the real template carries. Asserting the table lists all of
# them is Requirement 9.1's "one row per input".
DECLARED_PATHS = [
    "backend.accountId",
    "backend.region",
    "backend.profile",
    "frontend.accountId",
    "frontend.region",
    "frontend.profile",
    "ops.accountId",
    "ops.region",
    "ops.profile",
    "ops.escalationEmail",
    "upstream.org",
    "upstream.repo",
    "upstream.ref",
    "peer",
    "skillsEnabled",
    "operator.federationIdentifier",
    "bedrock.modelId",
    "escalation.mode",
]

BE_ID = fake_account_id(910_000_000_001)
FE_ID = fake_account_id(910_000_000_002)
OPS_ID = fake_account_id(910_000_000_003)
STALE_ID = fake_account_id(910_000_009_999)


def valid_config(**overrides) -> dict:
    """A config that satisfies every required field the template declares."""
    config = {
        "backend": {"accountId": BE_ID, "region": "us-east-1", "profile": "backend-app"},
        "frontend": {"accountId": FE_ID, "region": "us-east-1", "profile": "frontend-app"},
        "ops": {
            "accountId": OPS_ID,
            "region": "us-east-1",
            "profile": "monitoring",
            "escalationEmail": "team@example.com",
        },
        "operator": {"federationIdentifier": "some-federation-identity"},
    }
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(config.get(key), dict):
            config[key].update(value)
        else:
            config[key] = value
    return config


def make_preflight_repo(
    repo_factory,
    config: dict,
    check_parameters: str = STUB_PASS,
    scan_secrets: str = STUB_PASS,
    context: dict[str, list[str]] | None = None,
) -> Path:
    """Lay out a repo with preflight.sh, stub delegates, and cdk context caches.

    ``context`` maps a repo-relative directory to the account identifiers its
    cdk.context.json should contain.
    """
    root = repo_factory(config=config)
    shutil.copy2(PREFLIGHT, root / "scripts" / "preflight.sh")
    (root / "scripts" / "check-parameters.sh").write_text(check_parameters)
    (root / "scripts" / "scan-secrets.sh").write_text(scan_secrets)
    for directory, ids in (context or {}).items():
        target = root / directory if directory else root
        target.mkdir(parents=True, exist_ok=True)
        (target / "cdk.context.json").write_text(
            json.dumps({f"lookup:{i}": f"arn:aws:iam::{value}:role/r" for i, value in enumerate(ids)}, indent=2)
            + "\n"
        )
    return root


def api_calls(recorded: str) -> str:
    """The recorded invocations that would have left this machine.

    P6 shells out to the CLI on purpose, but only in modes that read the local
    service model. Requirement 9.2 is about calls that reach AWS, so those two
    modes are filtered out here.
    """
    return "\n".join(
        line
        for line in recorded.splitlines()
        if line.strip() and not any(mode in line for mode in OFFLINE_AWS_MODES)
    )


def run_preflight(
    root: Path, *args: str, aws_stub: str = AWS_STUB_MODERN
) -> tuple[subprocess.CompletedProcess, str]:
    """Run preflight with a recording ``aws`` stub first on PATH.

    Returns the completed process and the recorded invocations that would have
    reached AWS (the offline probes P6 makes are filtered out; the raw log stays
    at ``root / "aws-calls.log"`` for the test that asserts on it).
    """
    bindir = root / "stub-bin"
    bindir.mkdir(exist_ok=True)
    call_log = root / "aws-calls.log"
    if call_log.exists():
        call_log.unlink()
    stub = bindir / "aws"
    stub.write_text(aws_stub)
    stub.chmod(0o755)

    env = {
        "PATH": f"{bindir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
        "HOME": os.environ.get("HOME", str(root)),
        "AWS_CALL_LOG": str(call_log),
    }
    result = subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [BASH, str(root / "scripts" / "preflight.sh"), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    recorded = call_log.read_text() if call_log.exists() else ""
    return result, api_calls(recorded)


def output(result: subprocess.CompletedProcess) -> str:
    return result.stdout + result.stderr


# ─── R9.1 — one row per input, valid config passes ────────────────────────────


def test_valid_config_exits_zero_and_prints_every_declared_path(repo_factory):
    root = make_preflight_repo(repo_factory, valid_config())
    result, aws_calls = run_preflight(root)

    assert result.returncode == 0, output(result)
    for path in DECLARED_PATHS:
        assert path in result.stdout, f"{path} missing from the preflight table"
    assert "preflight: PASS" in result.stdout
    assert aws_calls == ""


def test_account_ids_are_redacted_unless_show_ids(repo_factory):
    root = make_preflight_repo(repo_factory, valid_config())

    default_run, _ = run_preflight(root)
    assert BE_ID not in output(default_run)
    assert f"********{BE_ID[-4:]}" in default_run.stdout

    shown_run, _ = run_preflight(root, "--show-ids")
    assert BE_ID in shown_run.stdout


# ─── R9.3 — every offending field listed ─────────────────────────────────────


def test_missing_required_inputs_all_listed_and_exit_non_zero(repo_factory):
    config = valid_config()
    del config["ops"]["escalationEmail"]
    del config["operator"]["federationIdentifier"]
    root = make_preflight_repo(repo_factory, config)

    result, aws_calls = run_preflight(root)
    combined = output(result)

    assert result.returncode != 0, combined
    assert "MISSING" in result.stdout
    # Both offenders, not just the first one.
    assert "ops.escalationEmail" in combined
    assert "operator.federationIdentifier" in combined
    assert "preflight: FAIL" in combined
    assert aws_calls == ""


def test_placeholder_inputs_are_reported_as_placeholders(repo_factory):
    config = valid_config(
        backend={"accountId": placeholder_id(1)},
        ops={"escalationEmail": "REPLACE_WITH_TEAM_EMAIL"},
    )
    root = make_preflight_repo(repo_factory, config)

    result, aws_calls = run_preflight(root)
    combined = output(result)

    assert result.returncode != 0, combined
    assert "PLACEHOLDER" in result.stdout
    assert "backend.accountId" in combined
    assert "ops.escalationEmail" in combined
    assert "placeholder" in combined.lower()
    assert aws_calls == ""


# ─── R9.4 — the three regions must agree ─────────────────────────────────────


def test_mismatched_regions_exit_non_zero_printing_all_three(repo_factory):
    config = valid_config()
    config["backend"]["region"] = "us-east-1"
    config["frontend"]["region"] = "us-west-2"
    config["ops"]["region"] = "eu-west-1"
    root = make_preflight_repo(repo_factory, config)

    result, aws_calls = run_preflight(root)
    combined = output(result)

    assert result.returncode != 0, combined
    assert "backend.region=us-east-1" in combined
    assert "frontend.region=us-west-2" in combined
    assert "ops.region=eu-west-1" in combined
    assert aws_calls == ""


# ─── R7.4 — stale cdk.context.json entries ───────────────────────────────────


def test_stale_context_entry_reported_with_its_file_name(repo_factory):
    root = make_preflight_repo(
        repo_factory,
        valid_config(),
        context={
            "agents/infra": [OPS_ID],
            "workload/frontend": [FE_ID, STALE_ID],
        },
    )

    result, aws_calls = run_preflight(root)
    combined = output(result)

    assert result.returncode != 0, combined
    assert "workload/frontend/cdk.context.json" in combined
    assert STALE_ID[-4:] in combined
    # The file holding only configured identifiers is not reported.
    assert "agents/infra/cdk.context.json" not in combined
    assert aws_calls == ""


def test_context_holding_only_configured_accounts_passes(repo_factory):
    root = make_preflight_repo(
        repo_factory,
        valid_config(),
        context={"": [BE_ID, FE_ID, OPS_ID], "agents/infra": [OPS_ID]},
    )

    result, aws_calls = run_preflight(root)

    assert result.returncode == 0, output(result)
    assert "P3 no stale cdk.context.json entry    PASS (2 file(s) scanned)" in result.stdout
    assert aws_calls == ""


# ─── Delegation and the blocking-vs-warning split ────────────────────────────


def test_check_parameters_failure_blocks(repo_factory):
    root = make_preflight_repo(
        repo_factory,
        valid_config(),
        check_parameters="#!/usr/bin/env bash\necho 'C2: undeclared path'\nexit 1\n",
    )

    result, _ = run_preflight(root)
    combined = output(result)

    assert result.returncode != 0, combined
    assert "check-parameters.sh exited 1" in combined


def test_scan_secrets_findings_warn_by_default_and_fail_under_strict(repo_factory):
    scan_stub = (
        "#!/usr/bin/env bash\n"
        f"printf 'some/fixture.test.ts:12:{fake_account_id(910_000_000_777)}\\n'\n"
        "exit 1\n"
    )
    root = make_preflight_repo(repo_factory, valid_config(), scan_secrets=scan_stub)

    default_run, aws_calls = run_preflight(root)
    assert default_run.returncode == 0, output(default_run)
    assert "WARN (1 finding(s)" in default_run.stdout
    assert "scan-secrets.sh exited 1" in default_run.stdout
    assert aws_calls == ""

    strict_run, _ = run_preflight(root, "--strict")
    assert strict_run.returncode != 0, output(strict_run)
    assert "repository-hygiene finding treated as failure" in output(strict_run)


def test_generated_resource_name_finding_is_counted(repo_factory):
    """A finding whose value is not twelve digits is still a finding.

    The scan reports generated resource names in the same file:line:value shape,
    so P5 counts the value field as "not a colon" rather than as an account ID —
    otherwise a real failure would be reported as "0 finding(s)".
    """
    # Assembled at runtime, for the same reason account IDs are: a committed
    # test file must not carry something the scan then has to reason about.
    generated_name = "-".join(["DevSampleStack", "Queue" + "AB12CD34", "Zq7XmT4vB2ke"])
    scan_stub = (
        "#!/usr/bin/env bash\n"
        f"printf 'docs/deployment.md:3305:{generated_name}\\n'\n"
        "exit 1\n"
    )
    root = make_preflight_repo(repo_factory, valid_config(), scan_secrets=scan_stub)

    result, _ = run_preflight(root)

    assert result.returncode == 0, output(result)
    assert "WARN (1 finding(s)" in result.stdout
    assert "docs/deployment.md:3305" in result.stdout


# ─── P6 — the `aws devops-agent` namespace and its asset (skills) API ────────


def test_devops_agent_model_present_passes(repo_factory):
    root = make_preflight_repo(repo_factory, valid_config())

    result, calls = run_preflight(root)

    assert result.returncode == 0, output(result)
    assert "P6 devops-agent CLI model resolves    PASS" in result.stdout
    assert "aws-cli/2.34.64" in result.stdout
    assert calls == ""


def test_preflight_only_invokes_the_cli_offline(repo_factory):
    """R9.2 — P6 shells out to `aws`, but never in a mode that reaches AWS."""
    root = make_preflight_repo(repo_factory, valid_config())

    run_preflight(root)
    recorded = (root / "aws-calls.log").read_text().splitlines()

    assert recorded, "P6 did not invoke the CLI at all"
    for line in recorded:
        assert any(mode in line for mode in OFFLINE_AWS_MODES), line
    # Both probes, because the two failure modes have different consequences.
    assert "devops-agent list-agent-spaces --generate-cli-skeleton" in recorded
    assert "devops-agent create-asset --generate-cli-skeleton" in recorded


def test_missing_asset_apis_warn_by_default_and_fail_under_strict(repo_factory):
    root = make_preflight_repo(repo_factory, valid_config())

    default_run, calls = run_preflight(root, aws_stub=AWS_STUB_NO_ASSET_APIS)
    assert default_run.returncode == 0, output(default_run)
    assert "WARN (asset/skill operations absent" in default_run.stdout
    # The remedy, and where the remedy is written down.
    assert "upload-skills.sh" in default_run.stdout
    assert "aws configure add-model" in default_run.stdout
    assert "--service-name devops-agent" in default_run.stdout
    assert DEVOPS_AGENT_DOC_ANCHOR in default_run.stdout
    assert calls == ""

    strict_run, _ = run_preflight(root, "--strict", aws_stub=AWS_STUB_NO_ASSET_APIS)
    assert strict_run.returncode != 0, output(strict_run)
    assert "FAIL (asset/skill operations absent, --strict)" in strict_run.stdout
    assert "DevOps Agent CLI-model finding treated as failure" in output(strict_run)


def test_missing_namespace_names_every_script_it_breaks(repo_factory):
    root = make_preflight_repo(repo_factory, valid_config())

    default_run, calls = run_preflight(root, aws_stub=AWS_STUB_NO_NAMESPACE)

    assert default_run.returncode == 0, output(default_run)
    assert "WARN (namespace unresolved" in default_run.stdout
    for script in (
        "register-webhook.sh",
        "register-platform-space-mcp.sh",
        "register-fallback-agents-mcp.sh",
        "upload-skills.sh",
        "smoke-test.sh",
    ):
        assert script in default_run.stdout, f"{script} not named in the P6 warning"
    assert "aws configure add-model" in default_run.stdout
    assert DEVOPS_AGENT_DOC_ANCHOR in default_run.stdout
    assert calls == ""

    strict_run, _ = run_preflight(root, "--strict", aws_stub=AWS_STUB_NO_NAMESPACE)
    assert strict_run.returncode != 0, output(strict_run)
    assert "FAIL (namespace unresolved, --strict)" in strict_run.stdout


def test_missing_config_file_exits_non_zero_naming_the_file(repo_factory):
    root = make_preflight_repo(repo_factory, valid_config())
    (root / "config" / "accounts.json").unlink()

    result, aws_calls = run_preflight(root)
    combined = output(result)

    assert result.returncode != 0, combined
    assert "config/accounts.json" in combined
    assert aws_calls == ""
