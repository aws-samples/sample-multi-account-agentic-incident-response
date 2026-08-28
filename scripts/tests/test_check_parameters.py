"""check-parameters.sh — the completeness proof's own tests.

The check is the load-bearing piece of Requirement 1.5: it is what makes
"every input is declared" enforced rather than asserted. A check that cannot
fail proves nothing, so each of C1-C4 is exercised against a temp-fixture
repository that violates exactly one rule, and once against a repository that
violates none.

Fixtures are whole miniature repositories under tmp_path: a template, a loader,
a shell script, a CDK stack, a Python runtime module. The real
`scripts/check-parameters.sh` is copied in, so it locates the fixture root from
its own path exactly as it locates the real one. The fixture trees are not git
repositories, which is what makes C5 (no new dependency, needing a baseline
ref) report SKIP there — it is covered against the real repository instead.

No 12-digit literal appears in this file (Requirement 6.5): the placeholder
identifiers the fixtures need come from ``placeholder_id``.

Requirements: 1.5
"""

from __future__ import annotations

import copy
import json
import shutil
import subprocess
from pathlib import Path

import pytest

from .conftest import BASH, REPO_ROOT, placeholder_id

CHECK_SCRIPT = REPO_ROOT / "scripts" / "check-parameters.sh"


def _doc_entry(
    *,
    required: bool,
    fmt: str = "string",
    default=None,
    description: str = "A fixture field.",
    consumed_by=("scripts/tests",),
    allowed=None,
    omit_default: bool = False,
) -> dict:
    entry: dict = {
        "required": required,
        "format": fmt,
        "description": description,
        "consumedBy": list(consumed_by),
    }
    if not required and not omit_default:
        entry["default"] = default
    if allowed is not None:
        entry["allowed"] = allowed
    return entry


# A minimal but valid parameter surface: one required account ID, one optional
# region carrying a default, one enumerated field. Small enough to reason about,
# shaped exactly like the real template.
BASE_TEMPLATE = {
    "_doc": {
        "$": "Fixture template. config/accounts.json is the only file a Replicator edits.",
        "ops.accountId": _doc_entry(required=True, fmt="accountId",
                                    description="12-digit OPS account ID."),
        "ops.region": _doc_entry(required=False, fmt="region", default="us-east-1",
                                 description="Region for the OPS account."),
        "ops.profile": _doc_entry(required=True, fmt="profile",
                                  description="Local CLI profile for the OPS account."),
        "peer": _doc_entry(required=False, default="both", allowed=["devops", "kb", "both"],
                           description="Which fallback agents to deploy."),
    },
    "ops": {
        "accountId": placeholder_id(3),
        "region": "us-east-1",
        "profile": "monitoring",
    },
    "peer": "both",
}

LOADER_JS = """// Fixture Cdk_Config_Loader. Only FIELDS matters to check C3.
const FIELDS = [
{fields}
];
module.exports = { FIELDS };
"""

CDK_STACK_TS = """import * as cdk from 'aws-cdk-lib';

export class FixtureStack extends cdk.Stack {
  constructor(scope: cdk.App, id: string) {
    super(scope, id);
    new cdk.CfnResource(this, 'R', {
      type: 'AWS::CloudFormation::WaitConditionHandle',
    });
  }
}

const commonEnv = {
  AWS_REGION: 'REGION',
};

const runtime = {
  environmentVariables: {
    ...commonEnv,
{keys}
  },
};
"""

RUNTIME_PY = '''"""Fixture Runtime_Component."""

import os


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


{body}
'''


def make_repo(
    tmp_path: Path,
    *,
    template: dict | None = None,
    loader_fields: list[str] | None = None,
    script_body: str | None = None,
    cdk_env_keys: list[str] | None = None,
    runtime_body: str | None = None,
    extra_files: dict[str, str] | None = None,
) -> Path:
    """Lay out a miniature repository and copy the real check script into it."""
    root = tmp_path / "repo"
    (root / "scripts").mkdir(parents=True)
    (root / "config").mkdir(parents=True)
    shutil.copy2(CHECK_SCRIPT, root / "scripts" / "check-parameters.sh")
    (root / "scripts" / "check-parameters.sh").chmod(0o755)

    tpl = copy.deepcopy(BASE_TEMPLATE) if template is None else template
    (root / "config" / "accounts.json.template").write_text(
        json.dumps(tpl, indent=2) + "\n"
    )

    fields = ["ops.accountId", "ops.region"] if loader_fields is None else loader_fields
    (root / "config" / "accounts-config.js").write_text(
        LOADER_JS.replace(
            "{fields}", "\n".join(f"  '{f}'," for f in fields)
        )
    )

    if script_body is not None:
        script = root / "scripts" / "deploy-fixture.sh"
        script.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + script_body + "\n")
        script.chmod(0o755)

    if cdk_env_keys is not None:
        stack = root / "agents" / "infra" / "lib"
        stack.mkdir(parents=True)
        (stack / "fixture-stack.ts").write_text(
            CDK_STACK_TS.replace(
                "{keys}", "\n".join(f"    {k}: 'value'," for k in cdk_env_keys)
            )
        )

    if runtime_body is not None:
        mod = root / "agents" / "shared"
        mod.mkdir(parents=True)
        (mod / "aws_tools.py").write_text(RUNTIME_PY.replace("{body}", runtime_body))

    for rel, content in (extra_files or {}).items():
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    return root


def _pending_section(stdout: str) -> str:
    """Just the pending-refactor block, so a test can assert on it alone."""
    lines = stdout.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("Pending refactor"):
            block: list[str] = []
            for rest in lines[i + 1:]:
                if not rest.strip():
                    break
                block.append(rest)
            return "\n".join(block)
    return ""


def run_check(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [BASH, str(root / "scripts" / "check-parameters.sh"), *args],
        capture_output=True,
        text=True,
        timeout=120,
    )


# ---------------------------------------------------------------------------
# The happy path: nothing is violated, so nothing may be reported.
# ---------------------------------------------------------------------------


def test_correct_repository_passes_every_check(tmp_path: Path):
    """A repository where C1-C4 all hold exits zero.

    C4 is made non-vacuous here on purpose: the fixture declares
    _require_env("BE_ACCOUNT_ID") and a CDK block that populates it, so the
    check has something to match rather than passing for want of call sites.
    """
    root = make_repo(
        tmp_path,
        script_body='config::get ops.region\nconfig::account ops\n',
        cdk_env_keys=["BE_ACCOUNT_ID"],
        runtime_body='BE_ACCOUNT_ID = _require_env("BE_ACCOUNT_ID")',
    )
    result = run_check(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "C1 template self-consistency          PASS" in result.stdout
    assert "C2 bash reads are declared            PASS" in result.stdout
    assert "C3 CDK reads are declared             PASS" in result.stdout
    assert "C4 required env vars have populators  PASS" in result.stdout
    assert "C6 no account/region/profile literals PASS" in result.stdout
    assert "FAILURES" not in result.stdout
    # No pending-refactor allowance is needed by a clean fixture: the C4 call
    # site exists, so the vacuity notice must not fire.
    assert "passes vacuously" not in result.stdout


# ---------------------------------------------------------------------------
# C1 — template self-consistency, both directions
# ---------------------------------------------------------------------------


def test_value_tree_field_absent_from_doc_fails_c1(tmp_path: Path):
    template = copy.deepcopy(BASE_TEMPLATE)
    template["ops"]["escalationEmail"] = "REPLACE_WITH_TEAM_EMAIL"
    root = make_repo(tmp_path, template=template)

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "ops.escalationEmail" in result.stdout
    assert "has no _doc entry" in result.stdout


def test_doc_entry_without_value_tree_field_fails_c1(tmp_path: Path):
    template = copy.deepcopy(BASE_TEMPLATE)
    template["_doc"]["ops.escalationEmail"] = _doc_entry(
        required=True, fmt="email", description="Owning-team email."
    )
    root = make_repo(tmp_path, template=template)

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "ops.escalationEmail" in result.stdout
    assert "the value tree does not declare" in result.stdout


def test_optional_entry_without_default_fails_c1(tmp_path: Path):
    template = copy.deepcopy(BASE_TEMPLATE)
    template["_doc"]["ops.region"] = _doc_entry(
        required=False, fmt="region", omit_default=True,
        description="Region for the OPS account.",
    )
    root = make_repo(tmp_path, template=template)

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert 'ops.region' in result.stdout
    assert "carries no \"default\"" in result.stdout


def test_underscore_prefixed_component_is_not_a_field(tmp_path: Path):
    """The underscore filter inspects every path component, not just the first.

    `operator._comment` is prose inside a value-tree object. It must neither be
    demanded of the _doc block nor reported as undocumented.
    """
    template = copy.deepcopy(BASE_TEMPLATE)
    template["_doc"]["operator.federationIdentifier"] = _doc_entry(
        required=True, description="Identity operators federate with."
    )
    template["operator"] = {
        "_comment": "Set this in the console Operator Access tab.",
        "federationIdentifier": "your-federation-identifier",
    }
    root = make_repo(tmp_path, template=template)

    result = run_check(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "_comment" not in result.stdout


# ---------------------------------------------------------------------------
# C2 — bash reads are declared
# ---------------------------------------------------------------------------


def test_script_reading_undeclared_path_through_resolver_fails_c2(tmp_path: Path):
    root = make_repo(tmp_path, script_body='config::get ops.escalationEmail')

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "scripts/deploy-fixture.sh:3" in result.stdout
    assert "ops.escalationEmail" in result.stdout
    assert "not declared in config/accounts.json.template" in result.stdout


def test_script_reading_undeclared_path_with_raw_jq_fails_c2(tmp_path: Path):
    """A script bypassing the resolver is caught by the same rule."""
    root = make_repo(
        tmp_path,
        script_body='EMAIL=$(jq -r \'.ops.escalationEmail\' "$CONFIG_FILE")',
    )

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "scripts/deploy-fixture.sh:3" in result.stdout
    assert "ops.escalationEmail" in result.stdout


def test_declared_raw_jq_read_is_a_failure_after_adoption(tmp_path: Path):
    """A raw read of a declared path is a defect now that task 11 has landed.

    Before the bash adoption wave this was a reported pending refactor, which is
    what let the gate be installed ahead of the wave. With every script on the
    resolver, the allowance is gone: bypassing the single shared location is a
    defect whether or not the path read happens to be declared (Requirement 2.6).
    """
    root = make_repo(
        tmp_path,
        script_body='OPS_REGION=$(jq -r \'.ops.region\' "$CONFIG_FILE")',
    )

    result = run_check(root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "bypass the Config_Resolver" in result.stdout
    # Reported as a defect, not parked on the pending list.
    assert "raw jq read" not in _pending_section(result.stdout)


# ---------------------------------------------------------------------------
# C3 — CDK reads are declared
# ---------------------------------------------------------------------------


def test_loader_field_absent_from_template_fails_c3(tmp_path: Path):
    root = make_repo(tmp_path, loader_fields=["ops.accountId", "bedrock.modelId"])

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "bedrock.modelId" in result.stdout
    assert "FIELDS entry" in result.stdout


def test_unenumerated_direct_reader_of_the_parameter_file_fails_c3(tmp_path: Path):
    """Any file other than the loader reading config/accounts.json is a defect.

    The four `bin/app.ts` files pending task 12 are enumerated in the script; a
    file that is not on that list fails immediately.
    """
    root = make_repo(
        tmp_path,
        extra_files={
            "tools/rogue.ts": (
                "import * as fs from 'fs';\n"
                "import * as path from 'path';\n"
                "const configPath = path.resolve(__dirname, '../config/accounts.json');\n"
                "const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));\n"
                "export default config;\n"
            )
        },
    )

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "tools/rogue.ts:4" in result.stdout
    assert "reads config/accounts.json directly" in result.stdout


def test_mentioning_the_parameter_file_name_is_not_a_read(tmp_path: Path):
    """Detection is line-level: a test building a fixture path is not a reader."""
    root = make_repo(
        tmp_path,
        extra_files={
            "agents/infra/test/loader.test.ts": (
                "import * as fs from 'fs';\n"
                "import * as path from 'path';\n"
                "const TEMPLATE = path.resolve(__dirname, '../../../config/accounts.json.template');\n"
                "const fixture = path.join('/tmp', 'accounts.json');\n"
                "const template = JSON.parse(fs.readFileSync(TEMPLATE, 'utf-8'));\n"
                "export { template, fixture };\n"
            )
        },
    )

    result = run_check(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "loader.test.ts" not in result.stdout


# ---------------------------------------------------------------------------
# C4 — required environment variables have a populator
# ---------------------------------------------------------------------------


def test_require_env_without_populator_fails_c4(tmp_path: Path):
    root = make_repo(
        tmp_path,
        cdk_env_keys=["BE_ACCOUNT_ID"],
        runtime_body='NOPE = _require_env("NOPE")',
    )

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "agents/shared/aws_tools.py" in result.stdout
    assert '_require_env("NOPE")' in result.stdout
    assert "has no populator" in result.stdout


def test_no_require_env_call_sites_is_reported_not_silent(tmp_path: Path):
    """C4's vacuity is stated in the output, never assumed."""
    root = make_repo(tmp_path, cdk_env_keys=["BE_ACCOUNT_ID"])

    result = run_check(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "passes vacuously" in result.stdout
    assert "_require_env() call sites" in result.stdout


# ---------------------------------------------------------------------------
# C6 — no account, region, or profile literal in any shell script
# ---------------------------------------------------------------------------


def test_profile_literal_in_a_script_fails_c6(tmp_path: Path):
    """The profile names come from the template, so the check needs no list."""
    root = make_repo(tmp_path, script_body='PROFILE="monitoring"')

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "scripts/deploy-fixture.sh:3" in result.stdout
    assert "CLI profile literal 'monitoring'" in result.stdout


def test_region_literal_in_a_script_fails_c6(tmp_path: Path):
    root = make_repo(tmp_path, script_body='REGION="us-east-1"')

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "region literal 'us-east-1'" in result.stdout


def test_account_id_literal_in_a_comment_fails_c6(tmp_path: Path):
    """Account identifiers are checked in comments too — a leak is a leak."""
    root = make_repo(
        tmp_path,
        script_body=f'# AccessDeniedException: Account {"9" * 12} is not authorized.',
    )

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert f"account identifier literal '{'9' * 12}'" in result.stdout


def test_c6_accepts_placeholders_prose_and_composed_names(tmp_path: Path):
    """The three boundaries the rules draw, in one fixture.

    A canonical placeholder identifier is the agreed stand-in; prose naming the
    ops profile or a region in a comment is documentation, not a value; a
    resource name that merely contains a profile name is a different string; and
    a 13-digit epoch is not a 12-digit account identifier.
    """
    epoch_ms = str(1785316323 * 1000 + 456)  # built at runtime: 13 digits
    root = make_repo(
        tmp_path,
        script_body=(
            "# The monitoring profile in us-east-1 is described, not used.\n"
            f'PLACEHOLDER="{placeholder_id(3)}"\n'
            'BUCKET="aiops-poc-monitoring-reports"\n'
            f'STAMP="{epoch_ms}"\n'
            'config::account ops'
        ),
    )

    result = run_check(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "FAILURES" not in result.stdout
    assert "C6 no account/region/profile literals PASS" in result.stdout


def test_documented_invocation_of_a_repo_script_with_a_profile_literal_fails_c6(
    tmp_path: Path,
):
    """The Markdown half of C6: docs are where a pasted literal actually bites.

    The script set comes from the repository walk, so a fixture script documented
    in a fixture markdown file is caught with nothing listed in the check.
    """
    root = make_repo(
        tmp_path,
        script_body="config::account ops",
        extra_files={
            "docs/runbook.md": (
                "Run it like this:\n"
                "\n"
                "```bash\n"
                "./scripts/deploy-fixture.sh --profile monitoring\n"
                "```\n"
            )
        },
    )

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "docs/runbook.md:4" in result.stdout
    assert "documented 'deploy-fixture.sh' invocation passes --profile monitoring" in result.stdout
    assert "drop the flag" in result.stdout


def test_c6_markdown_rule_leaves_prose_and_raw_aws_examples_alone(tmp_path: Path):
    """The deliberate boundaries of the Markdown rule, in one fixture.

    Prose naming the default profile is documentation. A raw `aws` example needs
    a profile passed, so a literal there is a style problem the rule does not
    judge — only an invocation of one of this repository's own scripts, which
    resolves its own profile, is unambiguously wrong.
    """
    root = make_repo(
        tmp_path,
        script_body="config::account ops",
        extra_files={
            "docs/runbook.md": (
                "The default OPS profile is `monitoring`; create one with that\n"
                "name (`aws configure --profile monitoring`) or override\n"
                "`ops.profile`.\n"
                "\n"
                "```bash\n"
                "aws s3 ls --profile <ops.profile> --region us-east-1\n"
                "aws ssm get-parameter --name /x --profile monitoring\n"
                "./scripts/deploy-fixture.sh\n"
                "```\n"
            )
        },
    )

    result = run_check(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "FAILURES" not in result.stdout
    assert "markdown file(s)" in result.stdout


def test_c6_exemption_that_no_longer_applies_is_itself_a_failure(tmp_path: Path):
    """The exemption list must not outlive its reason.

    The real script exempts one line of scripts/bootstrap.sh. A fixture tree with
    no bootstrap.sh cannot make that entry stale — the check only complains when
    the file exists and no longer contains the exempted text — so the fixture
    supplies a bootstrap.sh without it.
    """
    root = make_repo(
        tmp_path,
        extra_files={"scripts/bootstrap.sh": "#!/usr/bin/env bash\nconfig::account ops\n"},
    )

    result = run_check(root)
    assert result.returncode == 1, result.stdout
    assert "C6_EXEMPT lists 'monitoring' in scripts/bootstrap.sh" in result.stdout
    assert "remove the entry" in result.stdout


# ---------------------------------------------------------------------------
# The real repository
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("check", ["C1", "C2", "C3", "C4", "C5", "C6"])
def test_real_repository_reports_every_check(check: str):
    """The gate runs against the repository it guards and reports all six checks."""
    result = subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [BASH, str(CHECK_SCRIPT)],
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert any(
        line.strip().startswith(check) for line in result.stdout.splitlines()
    ), result.stdout
