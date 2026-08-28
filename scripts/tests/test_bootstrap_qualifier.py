"""Tests for the bootstrap qualifier guard in scripts/bootstrap.sh.

`cdk bootstrap` with no --toolkit-stack-name updates the CDKToolkit stack in
place, and updating a stack that was created for a *different* qualifier renames
its staging roles and asset bucket — deleting the resources every deployment
made under that qualifier depends on. Upstream PetAdoptions carries its own
qualifier in the backend account, so the run that would do the damage is ours.

Each case runs the real script against a throwaway repository holding the real
Config_Resolver, with `aws` and `cdk` replaced by recording stubs. The `aws` stub
answers the way CloudFormation would for one of the three states the guard
distinguishes, and the `cdk` stub records whether bootstrap was reached at all —
which is how "refuse" is verified rather than assumed.

The second half covers the other side of the same hazard: the bootstrap block the
upstream CodeBuild buildspec runs, extracted from
workload/backend/deploy/cfn-codebuild-stack.yaml, and the static assertion that
each of the four CDK apps pins its bootstrap qualifier.

No 12-digit literal appears in this file: identifiers come from
``fake_account_id`` in conftest (Requirement 6.5).

Requirements: 15.1
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from .conftest import BASH, REPO_ROOT, fake_account_id

BOOTSTRAP = REPO_ROOT / "scripts" / "bootstrap.sh"

BE_ID = fake_account_id(920_000_000_001)
FE_ID = fake_account_id(920_000_000_002)
OPS_ID = fake_account_id(920_000_000_003)

DEFAULT_QUALIFIER = "hnb659fds"
FOREIGN_QUALIFIER = "petsite"  # upstream PetAdoptions' own hardcoded value

# Every stub records its full argument list, so the assertions can tell "read the
# stack, then bootstrapped" from "bootstrapped without looking".
RECORD = 'printf "%s\\n" "$0 $*" >> "${CALL_LOG}"\n'

CDK_STUB = "#!/usr/bin/env bash\n" + RECORD + "exit 0\n"

# describe-stacks against an account with no CDKToolkit stack: the CLI writes a
# ValidationError to stderr and exits non-zero.
AWS_NO_STACK = (
    "#!/usr/bin/env bash\n"
    + RECORD
    + 'echo "An error occurred (ValidationError): Stack with id CDKToolkit does not exist" >&2\n'
    + "exit 254\n"
)


def aws_stub_returning(value: str) -> str:
    """An `aws` stub whose describe-stacks answers with one Qualifier value."""
    return (
        "#!/usr/bin/env bash\n"
        + RECORD
        + f'printf "%s\\n" "{value}"\n'
        + "exit 0\n"
    )


def config_json() -> dict:
    return {
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


def run_bootstrap(
    repo_factory, aws_stub: str, *args: str
) -> tuple[subprocess.CompletedProcess, list[str]]:
    """Run bootstrap.sh with stub `aws`/`cdk` first on PATH.

    Returns the completed process and every recorded stub invocation, in order.
    Preflight is skipped: it is covered by its own suite and would fail here on a
    fixture repo that carries no CDK apps.
    """
    root = repo_factory(config=config_json())
    shutil.copy2(BOOTSTRAP, root / "scripts" / "bootstrap.sh")

    bindir = root / "stub-bin"
    bindir.mkdir(exist_ok=True)
    for name, body in (("aws", aws_stub), ("cdk", CDK_STUB)):
        stub = bindir / name
        stub.write_text(body)
        stub.chmod(0o755)

    call_log = root / "calls.log"
    env = {
        "PATH": f"{bindir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
        "HOME": os.environ.get("HOME", str(root)),
        "CALL_LOG": str(call_log),
    }
    result = subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [BASH, str(root / "scripts" / "bootstrap.sh"), "--skip-preflight", *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    calls = call_log.read_text().splitlines() if call_log.exists() else []
    return result, calls


def output(result: subprocess.CompletedProcess) -> str:
    return result.stdout + result.stderr


def bootstrap_calls(calls: list[str]) -> list[str]:
    return [c for c in calls if "/cdk " in c or c.endswith("/cdk")]


def describe_calls(calls: list[str]) -> list[str]:
    return [c for c in calls if "describe-stacks" in c]


# ─── Branch 1 — no CDKToolkit stack ──────────────────────────────────────────


def test_no_existing_toolkit_stack_bootstraps(repo_factory) -> None:
    result, calls = run_bootstrap(repo_factory, AWS_NO_STACK, "--account", "be")

    assert result.returncode == 0, output(result)
    assert "no existing CDKToolkit stack" in result.stdout
    assert len(bootstrap_calls(calls)) == 1, calls
    assert f"aws://{BE_ID}/us-east-1" in bootstrap_calls(calls)[0]


# ─── Branch 2 — CDKToolkit stack on the default qualifier ────────────────────


def test_default_qualifier_proceeds(repo_factory) -> None:
    result, calls = run_bootstrap(
        repo_factory, aws_stub_returning(DEFAULT_QUALIFIER), "--account", "be"
    )

    assert result.returncode == 0, output(result)
    assert DEFAULT_QUALIFIER in result.stdout
    assert "safe to update" in result.stdout
    assert len(bootstrap_calls(calls)) == 1, calls


def test_stack_without_a_qualifier_parameter_proceeds(repo_factory) -> None:
    """An old bootstrap template declares no Qualifier; the CLI prints "None"."""
    result, calls = run_bootstrap(repo_factory, aws_stub_returning("None"), "--account", "be")

    assert result.returncode == 0, output(result)
    assert "safe to update" in result.stdout
    assert len(bootstrap_calls(calls)) == 1, calls


# ─── Branch 3 — CDKToolkit stack on a foreign qualifier ──────────────────────


def test_foreign_qualifier_refuses_without_bootstrapping(repo_factory) -> None:
    result, calls = run_bootstrap(
        repo_factory, aws_stub_returning(FOREIGN_QUALIFIER), "--account", "be"
    )

    assert result.returncode == 99, output(result)
    assert bootstrap_calls(calls) == [], "refused, yet cdk bootstrap still ran"
    assert describe_calls(calls), "the guard never read the existing stack"


def test_refusal_names_account_qualifier_consequence_and_remedy(repo_factory) -> None:
    result, _ = run_bootstrap(
        repo_factory, aws_stub_returning(FOREIGN_QUALIFIER), "--account", "be"
    )
    message = result.stderr

    # which account
    assert BE_ID in message
    assert "us-east-1" in message
    assert "backend-app" in message
    # the qualifier found, and the one we wanted
    assert FOREIGN_QUALIFIER in message
    assert DEFAULT_QUALIFIER in message
    # what updating it would do
    assert f"cdk-{FOREIGN_QUALIFIER}-*" in message
    assert "deleted" in message
    assert f"/cdk-bootstrap/{FOREIGN_QUALIFIER}/version" in message
    # what to do instead, as a concrete command
    assert "--toolkit-stack-name CDKToolkitDefault" in message
    assert f"--qualifier {DEFAULT_QUALIFIER}" in message
    assert f"cdk bootstrap aws://{BE_ID}/us-east-1 --profile backend-app" in message
    # and where the long form lives
    assert (
        "docs/deployment.md#troubleshooting-two-cdk-toolkit-stacks-in-one-account"
        in message
    )


def test_refusal_stops_before_later_accounts(repo_factory) -> None:
    """A refusal on the first account must not bootstrap the other two."""
    result, calls = run_bootstrap(repo_factory, aws_stub_returning(FOREIGN_QUALIFIER))

    assert result.returncode == 99, output(result)
    assert bootstrap_calls(calls) == [], calls
    assert len(describe_calls(calls)) == 1, "kept going after refusing"


# ─── The refusal names the retained staging bucket the remedy trips over ─────


def test_refusal_covers_the_retained_staging_bucket(repo_factory) -> None:
    """The documented remedy fails without this step, so the message must carry it.

    CDK's bootstrap template names the staging bucket from the QUALIFIER, not from
    the stack name (``cdk-${Qualifier}-assets-${AWS::AccountId}-${AWS::Region}``),
    and it is the only bootstrap resource carrying ``DeletionPolicy: Retain``. So a
    bucket orphaned by an earlier bootstrap of the default qualifier outlives its
    stack, a fresh ``CDKToolkitDefault`` derives the same name, and the command the
    refusal prints dies with ``AlreadyExists`` — which is what happened to this
    PoC's backend account.
    """
    result, _ = run_bootstrap(
        repo_factory, aws_stub_returning(FOREIGN_QUALIFIER), "--account", "be"
    )
    message = result.stderr
    bucket = f"cdk-{DEFAULT_QUALIFIER}-assets-{BE_ID}-us-east-1"

    # The exact bucket, resolved for the account being refused.
    assert bucket in message
    # Why it is there at all, and what it breaks.
    assert "Retain" in message
    assert "AlreadyExists" in message
    # The check, as runnable commands: does it exist, and is it empty.
    assert f"aws s3api head-bucket --bucket {bucket}" in message
    assert f"aws s3api list-objects-v2 --bucket {bucket}" in message
    # Deleting it, only in the empty case.
    assert f"aws s3 rb s3://{bucket}" in message
    assert "empty" in message
    # And an explicit stop for the non-empty case, with a way to find the owner.
    assert "do not delete it" in message.lower()
    assert f"aws s3api get-bucket-tagging --bucket {bucket}" in message
    # Ordered: clear the bucket, then create the stack.
    assert message.index("head-bucket") < message.index(
        "--toolkit-stack-name CDKToolkitDefault"
    )


# ─── The guard cannot lock an operator out ───────────────────────────────────


def test_unreadable_stack_state_still_bootstraps(repo_factory) -> None:
    """A missing describe-stacks permission reads as "no stack", not as a refusal."""
    aws_denied = (
        "#!/usr/bin/env bash\n"
        + RECORD
        + 'echo "An error occurred (AccessDenied)" >&2\n'
        + "exit 254\n"
    )
    result, calls = run_bootstrap(repo_factory, aws_denied, "--account", "be")

    assert result.returncode == 0, output(result)
    assert len(bootstrap_calls(calls)) == 1, calls


# ─── The bootstrap itself passes --qualifier, so it cannot inherit one ───────
#
# `cdk bootstrap` with no --qualifier reuses the existing stack's Qualifier
# parameter. On an account whose CDKToolkit has been flipped, a bare invocation
# therefore re-bootstraps the *foreign* qualifier and prints
# "bootstrapped (no changes)" while /cdk-bootstrap/hnb659fds/version stays absent —
# a repair command that claims success and fixes nothing. Same shape as
# BuildTimeoutMinutes' UsePreviousValue trap: a parameter you do not pass is
# inherited, so the fix is a no-op exactly where it is needed.


def test_bootstrap_passes_the_qualifier_when_no_stack_exists(repo_factory) -> None:
    _, calls = run_bootstrap(repo_factory, AWS_NO_STACK, "--account", "be")

    assert f"--qualifier {DEFAULT_QUALIFIER}" in bootstrap_calls(calls)[0], calls


def test_bootstrap_passes_the_qualifier_on_the_default_qualifier_path(
    repo_factory,
) -> None:
    _, calls = run_bootstrap(
        repo_factory, aws_stub_returning(DEFAULT_QUALIFIER), "--account", "be"
    )

    assert f"--qualifier {DEFAULT_QUALIFIER}" in bootstrap_calls(calls)[0], calls


def test_bootstrap_passes_the_qualifier_on_the_fail_open_path(repo_factory) -> None:
    """The path that matters: unreadable state, so the refusal cannot guard it.

    existing_toolkit_qualifier fails open on purpose — an unreadable
    describe-stacks must never become a refusal to bootstrap — and that leaves the
    explicit qualifier as the only thing standing between a flipped stack and a
    silent re-bootstrap under someone else's qualifier.
    """
    aws_denied = (
        "#!/usr/bin/env bash\n"
        + RECORD
        + 'echo "An error occurred (AccessDenied)" >&2\n'
        + "exit 254\n"
    )
    result, calls = run_bootstrap(repo_factory, aws_denied, "--account", "be")

    assert result.returncode == 0, output(result)
    assert f"--qualifier {DEFAULT_QUALIFIER}" in bootstrap_calls(calls)[0], calls


def test_every_account_is_bootstrapped_with_the_qualifier(repo_factory) -> None:
    """All three accounts, not just the first one the loop reaches."""
    _, calls = run_bootstrap(repo_factory, AWS_NO_STACK)

    boots = bootstrap_calls(calls)
    assert len(boots) == 3, boots
    for call in boots:
        assert f"--qualifier {DEFAULT_QUALIFIER}" in call, call


# ─── The four CDK apps pin the qualifier explicitly ──────────────────────────

CDK_APPS = [
    "agent-spaces",
    "agents/infra",
    "workload/backend/overlay",
    "workload/frontend",
]


@pytest.mark.parametrize("app", CDK_APPS)
def test_cdk_app_pins_the_default_qualifier(app: str) -> None:
    """Every app pins DefaultStackSynthesizer, so no ambient context can move it.

    The pin is what keeps a synth run from inheriting another qualifier out of a
    cdk.json that happens to be in scope. Asserting on the source is deliberate:
    the synthesized output is identical either way — that is the point of the pin
    — so a template assertion could not observe it.
    """
    source = (REPO_ROOT / app / "bin" / "app.ts").read_text()

    assert "cdk.DefaultStackSynthesizer" in source, (
        f"{app} relies on the ambient bootstrap qualifier"
    )
    assert "cdk.DefaultStackSynthesizer.DEFAULT_QUALIFIER" in source, (
        f"{app} should pin CDK's own default rather than a qualifier literal"
    )

    # Every stack the app declares carries the pin, not just the first one.
    stacks = re.findall(r"new\s+(\w*Stack)\s*\(\s*app\s*,", source)
    assert stacks, f"no stack instantiation found in {app}/bin/app.ts"
    assert source.count("synthesizer: synthesizer()") == len(stacks), (
        f"{app} declares {len(stacks)} stack(s) {stacks} but pins "
        f"{source.count('synthesizer: synthesizer()')} of them"
    )


# ─── The upstream buildspec bootstraps into its own toolkit stack ─────────────
#
# The block under test is one command entry inside the CodeBuild buildspec that
# workload/backend/deploy/cfn-codebuild-stack.yaml embeds. It is extracted from
# the template rather than copied here, so these cases fail if the template stops
# containing it. CodeBuild runs buildspec commands through /bin/sh, so does this.

CFN_TEMPLATE = (
    REPO_ROOT / "workload" / "backend" / "deploy" / "cfn-codebuild-stack.yaml"
)

SH = shutil.which("sh") or "/bin/sh"


def buildspec_bootstrap_block() -> str:
    """The bootstrap command entry from the embedded buildspec.

    CloudFormation intrinsics are loaded as plain scalars: the block asserted on
    carries no ``${...}`` of its own precisely so that !Sub leaves it alone.
    """
    yaml = pytest.importorskip("yaml", reason="PyYAML is needed to read the template")

    class Loader(yaml.SafeLoader):
        pass

    def passthrough(loader, tag_suffix, node):
        if isinstance(node, yaml.ScalarNode):
            return loader.construct_scalar(node)
        if isinstance(node, yaml.SequenceNode):
            return loader.construct_sequence(node)
        return loader.construct_mapping(node)

    Loader.add_multi_constructor("!", passthrough)

    template = yaml.load(CFN_TEMPLATE.read_text(), Loader=Loader)
    spec = template["Resources"]["UpstreamDeployProject"]["Properties"]["Source"][
        "BuildSpec"
    ]
    commands = yaml.safe_load(spec)["phases"]["build"]["commands"]
    blocks = [c for c in commands if isinstance(c, str) and "QUALIFIER=" in c]

    assert len(blocks) == 1, f"expected one bootstrap block, found {len(blocks)}"
    assert "${" not in blocks[0], (
        "the block is embedded in a !Sub template, so a ${...} in it would be "
        "substituted by CloudFormation"
    )
    return blocks[0]


def run_buildspec_bootstrap(
    tmp_path: Path, cdk_json: dict, cdk_stub: str = CDK_STUB
) -> tuple[subprocess.CompletedProcess, list[str]]:
    """Run the extracted block against a fixture cdk.json with a stub `cdk`."""
    work = tmp_path / "upstream-cdk"
    work.mkdir()
    (work / "cdk.json").write_text(json.dumps(cdk_json, indent=2) + "\n")

    bindir = tmp_path / "stub-bin"
    bindir.mkdir()
    stub = bindir / "cdk"
    stub.write_text(cdk_stub)
    stub.chmod(0o755)

    script = tmp_path / "block.sh"
    script.write_text(buildspec_bootstrap_block() + "\n")

    call_log = tmp_path / "calls.log"
    result = subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [SH, str(script)],
        cwd=work,
        env={
            "PATH": f"{bindir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "HOME": os.environ.get("HOME", str(tmp_path)),
            "CALL_LOG": str(call_log),
            "CDK_DIR": str(work),
            "UPSTREAM_REF": "some-pinned-ref",
        },
        capture_output=True,
        text=True,
        timeout=120,
    )
    calls = call_log.read_text().splitlines() if call_log.exists() else []
    return result, calls


def test_buildspec_bootstraps_upstream_qualifier_into_its_own_stack(tmp_path) -> None:
    result, calls = run_buildspec_bootstrap(
        tmp_path,
        {"context": {"@aws-cdk/core:bootstrapQualifier": FOREIGN_QUALIFIER}},
    )

    assert result.returncode == 0, output(result)
    assert len(calls) == 1, calls
    assert f"--qualifier {FOREIGN_QUALIFIER}" in calls[0]
    # Upstream's own scripts/bootstrap-account.sh naming.
    assert "--toolkit-stack-name CDKToolkitPetsite" in calls[0]


def test_buildspec_fails_loudly_when_the_qualifier_key_is_absent(tmp_path) -> None:
    """No silent fallback to a bare `cdk bootstrap` — that is the original bug."""
    result, calls = run_buildspec_bootstrap(tmp_path, {"context": {}})

    assert result.returncode != 0
    assert calls == [], "fell back to bootstrapping anyway"
    assert "bootstrapQualifier" in result.stderr
    assert "some-pinned-ref" in result.stderr, "the ref in play is not named"


def test_buildspec_fails_the_build_when_bootstrap_fails(tmp_path) -> None:
    """A bootstrap failure is no longer swallowed by `|| echo already done`."""
    failing_cdk = "#!/usr/bin/env bash\n" + RECORD + 'echo "boom" >&2\nexit 3\n'
    result, calls = run_buildspec_bootstrap(
        tmp_path,
        {"context": {"@aws-cdk/core:bootstrapQualifier": FOREIGN_QUALIFIER}},
        cdk_stub=failing_cdk,
    )

    assert result.returncode == 3, output(result)
    assert len(calls) == 1, calls
    # The message names both the stack and the qualifier involved.
    assert "CDKToolkitPetsite" in result.stderr
    assert FOREIGN_QUALIFIER in result.stderr


def test_buildspec_reports_an_up_to_date_bootstrap_as_nothing_to_do(tmp_path) -> None:
    """"Already bootstrapped" is read off the log, not guessed from an exit code."""
    quiet_cdk = (
        "#!/usr/bin/env bash\n"
        + RECORD
        + 'echo " ✅  Environment aws://x/y bootstrapped (no changes)."\n'
        + "exit 0\n"
    )
    result, _ = run_buildspec_bootstrap(
        tmp_path,
        {"context": {"@aws-cdk/core:bootstrapQualifier": FOREIGN_QUALIFIER}},
        cdk_stub=quiet_cdk,
    )

    assert result.returncode == 0, output(result)
    assert "already up to date, nothing to do" in result.stdout
    assert "created or updated" not in result.stdout


def test_buildspec_rejects_a_qualifier_that_is_not_a_qualifier(tmp_path) -> None:
    """Whatever upstream puts in cdk.json never reaches a stack name unchecked."""
    result, calls = run_buildspec_bootstrap(
        tmp_path,
        {"context": {"@aws-cdk/core:bootstrapQualifier": "Pet Site; rm -rf /"}},
    )

    assert result.returncode != 0
    assert calls == [], calls
