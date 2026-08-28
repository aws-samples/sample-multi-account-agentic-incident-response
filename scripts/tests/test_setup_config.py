"""Tests for scripts/setup-config.sh — the Setup_Wizard (task 9.5).

Every case runs the real script against a throwaway repository holding the real
Config_Resolver, the real parameter template and the real Preflight_Command,
with check-parameters.sh and scan-secrets.sh stubbed so that a test exercises
one wizard behaviour rather than the whole repository's hygiene state.

Interactive cases drive the wizard through piped stdin — the same thing a
Replicator does with a keyboard, one line per answer.

Every run happens with a recording ``aws`` stub first on PATH. The wizard's only
permitted AWS call is ``sts get-caller-identity``; asserting on that recording is
how Requirements 11.16 and 11.17 are verified rather than assumed.

No 12-digit literal appears in this file: identifiers come from
``fake_account_id`` / ``placeholder_id`` in conftest (Requirement 6.5).

Validates: Requirements 11.1, 11.2, 11.5, 11.6, 11.7, 11.8, 11.9, 11.10, 11.11,
11.12, 11.13, 11.14, 11.15, 11.16, 11.17, 11.18, 11.19, 11.20, 11.21
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

from .conftest import BASH, REPO_ROOT, fake_account_id, placeholder_id

SETUP = REPO_ROOT / "scripts" / "setup-config.sh"
PREFLIGHT = REPO_ROOT / "scripts" / "preflight.sh"
REAL_TEMPLATE = REPO_ROOT / "config" / "accounts.json.template"

STUB_PASS = "#!/usr/bin/env bash\nexit 0\n"  # nosec B105  # stub shell script body, not a credential

BE_ID = fake_account_id(920_000_000_001)
FE_ID = fake_account_id(920_000_000_002)
OPS_ID = fake_account_id(920_000_000_003)
OTHER_ID = fake_account_id(920_000_000_777)

EMAIL = "team@example.com"
FEDERATION = "some-federation-identity"

# The five required inputs, supplied the way an automated caller supplies them.
# The list is the template's required set, not a wizard-side list: task 9.5's
# template-driven case below proves the wizard reads it from the template.
# The three CLI profiles are optional (they default to the conventional
# profile names); tests that want specific profile values supply them via
# --set, which is fine for an optional field.
REQUIRED = [
    f"backend.accountId={BE_ID}",
    f"frontend.accountId={FE_ID}",
    f"ops.accountId={OPS_ID}",
    f"ops.escalationEmail={EMAIL}",
    f"operator.federationIdentifier={FEDERATION}",
]


def set_flags(*assignments: str) -> list[str]:
    flags: list[str] = []
    for assignment in assignments:
        flags += ["--set", assignment]
    return flags


def template_doc() -> dict:
    return json.loads(REAL_TEMPLATE.read_text())["_doc"]


def template_defaults() -> dict[str, object]:
    """Every optional field's declared default, read from the real template."""
    return {
        path: entry["default"]
        for path, entry in template_doc().items()
        if isinstance(entry, dict) and entry.get("required") is False
    }


def written(root: Path) -> dict:
    return json.loads((root / "config" / "accounts.json").read_text())


def at_path(document: dict, path: str):
    node = document
    for part in path.split("."):
        node = node[part]
    return node


def make_wizard_repo(repo_factory, config: dict | None = None, template: dict | None = None) -> Path:
    """A repo with the wizard, the real preflight, and stub delegates."""
    root = repo_factory(
        config=config,
        template=template,
        write_config=config is not None,
    )
    shutil.copy2(SETUP, root / "scripts" / "setup-config.sh")
    shutil.copy2(PREFLIGHT, root / "scripts" / "preflight.sh")
    (root / "scripts" / "check-parameters.sh").write_text(STUB_PASS)
    (root / "scripts" / "scan-secrets.sh").write_text(STUB_PASS)
    return root


# The wizard hands off to the real preflight.sh, whose check P6 probes the local
# `aws devops-agent` service model with `--version` and
# `--generate-cli-skeleton`. Both modes resolve the model on disk and contact
# nothing, so they are not AWS calls in the sense these tests assert on; they are
# filtered out below and asserted in test_preflight.py instead.
OFFLINE_AWS_MODES = ("--version", "--generate-cli-skeleton")


def run_wizard(
    root: Path,
    *args: str,
    stdin: str = "",
    stub_account: str | None = None,
    stub_arn: str | None = None,
) -> tuple[subprocess.CompletedProcess, list[str]]:
    """Run the wizard with a recording ``aws`` stub, returning its AWS calls."""
    bindir = root / "stub-bin"
    bindir.mkdir(exist_ok=True)
    call_log = root / "aws-calls.log"
    stub = bindir / "aws"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        'printf "%s\\n" "$*" >> "${AWS_CALL_LOG}"\n'
        'printf "{\\"Account\\":\\"%s\\",\\"Arn\\":\\"%s\\"}\\n" '
        '"${AWS_STUB_ACCOUNT:-}" "${AWS_STUB_ARN:-}"\n'
    )
    stub.chmod(0o755)

    env = {
        "PATH": f"{bindir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
        "HOME": os.environ.get("HOME", str(root)),
        "AWS_CALL_LOG": str(call_log),
    }
    if stub_account is not None:
        env["AWS_STUB_ACCOUNT"] = stub_account
    if stub_arn is not None:
        env["AWS_STUB_ARN"] = stub_arn

    result = subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [BASH, str(root / "scripts" / "setup-config.sh"), *args],
        input=stdin,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )
    recorded = call_log.read_text().splitlines() if call_log.exists() else []
    calls = [
        line
        for line in recorded
        if line and not any(mode in line for mode in OFFLINE_AWS_MODES)
    ]
    return result, calls


def output(result: subprocess.CompletedProcess) -> str:
    return result.stdout + result.stderr


def valid_config() -> dict:
    return {
        "backend": {"accountId": BE_ID, "region": "us-east-1", "profile": "be-profile"},
        "frontend": {"accountId": FE_ID, "region": "us-east-1", "profile": "fe-profile"},
        "ops": {
            "accountId": OPS_ID,
            "region": "us-east-1",
            "profile": "ops-profile",
            "escalationEmail": EMAIL,
        },
        "upstream": {"org": "aws-samples", "repo": "one-observability-demo", "ref": "main"},
        "peer": "kb",
        "skillsEnabled": False,
        "operator": {"federationIdentifier": FEDERATION},
        "bedrock": {"modelId": "some.model.id"},
        "escalation": {"mode": "auto"},
    }


# ─── R11.5, R11.6, R11.18, R11.20, 1.6 — a complete non-interactive run ──────


def test_non_interactive_run_writes_every_field_with_optional_defaults(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, calls = run_wizard(
        root, "--non-interactive", "--no-verify", *set_flags(*REQUIRED)
    )

    # R11.20: the exit status is preflight's, and preflight passes on this config.
    assert result.returncode == 0, output(result)
    assert "preflight: PASS" in result.stdout
    assert calls == []

    document = written(root)
    assert at_path(document, "backend.accountId") == BE_ID
    assert at_path(document, "frontend.accountId") == FE_ID
    assert at_path(document, "ops.accountId") == OPS_ID
    assert at_path(document, "ops.escalationEmail") == EMAIL
    assert at_path(document, "operator.federationIdentifier") == FEDERATION

    # R11.5: every optional field is present at the template's declared default.
    for path, default in template_defaults().items():
        assert at_path(document, path) == default, f"{path} not at its template default"

    # R11.6 / 1.6: same JSON shape as the template, _doc and key order included.
    template = json.loads(REAL_TEMPLATE.read_text())
    assert list(document.keys()) == list(template.keys())
    assert document["_doc"] == template["_doc"]
    # skillsEnabled stays a JSON boolean rather than becoming the string "true".
    assert at_path(document, "skillsEnabled") is True


def test_profiles_default_to_the_conventional_names_when_not_supplied(repo_factory):
    """A run with only the five required values writes the conventional profiles."""
    root = make_wizard_repo(repo_factory)

    result, _ = run_wizard(root, "--non-interactive", "--no-verify", *set_flags(*REQUIRED))

    assert result.returncode == 0, output(result)
    document = written(root)
    assert at_path(document, "backend.profile") == "backend-app"
    assert at_path(document, "frontend.profile") == "frontend-app"
    assert at_path(document, "ops.profile") == "monitoring"


# ─── R11.7, R11.8 — a re-run is an edit, not a restart ───────────────────────


def test_rerun_with_force_and_no_new_answers_preserves_every_value(repo_factory):
    existing = valid_config()
    root = make_wizard_repo(repo_factory, config=existing)

    # One empty line per prompt: every answer is "keep what is there" (R11.8).
    result, _ = run_wizard(root, "--force", "--no-verify", stdin="\n" * 12)

    assert result.returncode == 0, output(result)
    document = written(root)
    for path in [
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
    ]:
        assert at_path(document, path) == at_path(existing, path), f"{path} was not preserved"


def test_without_force_an_existing_file_is_left_untouched(repo_factory):
    root = make_wizard_repo(repo_factory, config=valid_config())
    target = root / "config" / "accounts.json"
    before = target.read_bytes()

    result, _ = run_wizard(
        root,
        "--non-interactive",
        "--no-verify",
        *set_flags(f"backend.accountId={OTHER_ID}", *REQUIRED),
    )

    assert result.returncode != 0, output(result)
    assert "--force" in output(result)
    assert target.read_bytes() == before


def test_declining_the_typed_confirmation_leaves_the_file_untouched(repo_factory):
    root = make_wizard_repo(repo_factory, config=valid_config())
    target = root / "config" / "accounts.json"
    before = target.read_bytes()

    result, _ = run_wizard(root, "--no-verify", stdin="no\n")

    assert result.returncode != 0, output(result)
    assert "unchanged" in output(result)
    assert target.read_bytes() == before


def test_typed_confirmation_allows_the_overwrite(repo_factory):
    root = make_wizard_repo(repo_factory, config=valid_config())

    result, _ = run_wizard(root, "--no-verify", stdin="overwrite\n" + "\n" * 12)

    assert result.returncode == 0, output(result)
    assert at_path(written(root), "backend.accountId") == BE_ID


# ─── R11.9-11.13 — rejections ────────────────────────────────────────────────


def test_short_account_id_is_rejected_and_the_same_input_is_prompted_again(repo_factory):
    root = make_wizard_repo(repo_factory)

    answers = [
        BE_ID[:-1],  # eleven digits — must be rejected
        BE_ID,
        FE_ID,
        OPS_ID,
        EMAIL,
        FEDERATION,
    ]
    result, _ = run_wizard(root, "--no-verify", stdin="".join(f"{a}\n" for a in answers))

    combined = output(result)
    assert "12 decimal digits" in combined
    # The re-prompt landed on the same input, so the remaining answers still line
    # up and the run completes with the corrected identifier.
    assert result.returncode == 0, combined
    assert at_path(written(root), "backend.accountId") == BE_ID


def test_placeholder_account_id_is_rejected(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, _ = run_wizard(
        root,
        "--non-interactive",
        "--no-verify",
        *set_flags(*REQUIRED, f"backend.accountId={placeholder_id(1)}"),
    )

    combined = output(result)
    assert result.returncode != 0, combined
    assert "backend.accountId" in combined
    assert "placeholder" in combined.lower()
    assert not (root / "config" / "accounts.json").exists()


def test_out_of_domain_enum_value_is_rejected_listing_the_allowed_values(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, _ = run_wizard(
        root, "--non-interactive", "--no-verify", *set_flags(*REQUIRED, "peer=sideways")
    )

    combined = output(result)
    assert result.returncode != 0, combined
    assert "peer" in combined
    for allowed in template_doc()["peer"]["allowed"]:
        assert allowed in combined
    assert not (root / "config" / "accounts.json").exists()


def test_malformed_email_is_rejected(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, _ = run_wizard(
        root,
        "--non-interactive",
        "--no-verify",
        *set_flags(*REQUIRED, "ops.escalationEmail=team-at-example"),
    )

    combined = output(result)
    assert result.returncode != 0, combined
    assert "ops.escalationEmail" in combined
    assert not (root / "config" / "accounts.json").exists()


def test_mismatched_regions_are_reported_with_all_three_values(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, _ = run_wizard(
        root,
        "--non-interactive",
        "--no-verify",
        *set_flags(
            *REQUIRED,
            "backend.region=us-east-1",
            "frontend.region=us-west-2",
            "ops.region=eu-west-1",
        ),
    )

    combined = output(result)
    assert result.returncode != 0, combined
    assert "backend.region=us-east-1" in combined
    assert "frontend.region=us-west-2" in combined
    assert "ops.region=eu-west-1" in combined
    assert not (root / "config" / "accounts.json").exists()


def test_mismatched_regions_are_reprompted_and_the_run_completes(repo_factory):
    root = make_wizard_repo(repo_factory)

    answers = [
        BE_ID,
        "us-east-1",
        "be-profile",
        FE_ID,
        "us-west-2",  # the odd one out
        "fe-profile",
        OPS_ID,
        "us-east-1",
        "ops-profile",
        EMAIL,
        "aws-samples",
        "one-observability-demo",
        "main",
        "both",
        "true",
        FEDERATION,
        "some.model.id",
        "always",
        # the three regions again, in agreement this time
        "us-east-1",
        "us-east-1",
        "us-east-1",
    ]
    result, _ = run_wizard(
        root,
        "--no-verify",
        "--include-optional",
        stdin="".join(f"{a}\n" for a in answers),
    )

    combined = output(result)
    assert result.returncode == 0, combined
    assert "not in the same region" in combined
    document = written(root)
    assert (
        at_path(document, "backend.region")
        == at_path(document, "frontend.region")
        == at_path(document, "ops.region")
        == "us-east-1"
    )


# ─── R11.19 — non-interactive with a value missing ───────────────────────────


def test_missing_required_value_in_non_interactive_mode_names_the_json_path(repo_factory):
    root = make_wizard_repo(repo_factory)
    incomplete = [entry for entry in REQUIRED if not entry.startswith("ops.escalationEmail=")]

    result, _ = run_wizard(root, "--non-interactive", "--no-verify", *set_flags(*incomplete))

    combined = output(result)
    assert result.returncode != 0, combined
    assert "ops.escalationEmail" in combined
    assert not (root / "config" / "accounts.json").exists()


def test_canonical_env_variables_supply_values_in_non_interactive_mode(repo_factory):
    root = make_wizard_repo(repo_factory)
    incomplete = [entry for entry in REQUIRED if not entry.startswith("ops.escalationEmail=")]

    bindir = root / "stub-bin"
    bindir.mkdir(exist_ok=True)
    env_result = subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [
            BASH,
            str(root / "scripts" / "setup-config.sh"),
            "--non-interactive",
            "--no-verify",
            *set_flags(*incomplete),
        ],
        env={
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": os.environ.get("HOME", str(root)),
            "AIOPS_OPS_ESCALATIONEMAIL": EMAIL,
        },
        capture_output=True,
        text=True,
        timeout=180,
    )

    assert env_result.returncode == 0, env_result.stdout + env_result.stderr
    assert at_path(written(root), "ops.escalationEmail") == EMAIL


# ─── R11.14-11.17 — the AWS calls, and the ones never made ───────────────────


def test_no_verify_makes_zero_aws_calls(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, calls = run_wizard(
        root, "--non-interactive", "--no-verify", *set_flags(*REQUIRED)
    )

    assert result.returncode == 0, output(result)
    assert calls == []


def test_verification_calls_only_get_caller_identity(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, calls = run_wizard(
        root, "--non-interactive", *set_flags(*REQUIRED), stub_account=BE_ID
    )

    assert result.returncode == 0, output(result)
    assert len(calls) == 3, calls
    for call in calls:
        assert call.startswith("sts get-caller-identity "), call
        assert "--profile" in call


def test_account_mismatch_warns_and_continues(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, calls = run_wizard(
        root, "--non-interactive", *set_flags(*REQUIRED), stub_account=OTHER_ID
    )

    combined = output(result)
    # R11.15: a warning, and a zero exit status for that check — the file is
    # written as entered and preflight still gets the last word.
    assert result.returncode == 0, combined
    assert "but you entered" in combined
    assert OTHER_ID[-4:] in combined
    assert len(calls) == 3, calls
    assert at_path(written(root), "backend.accountId") == BE_ID


# ─── The federation-identifier session name (deployment finding 2) ──────────
#
# operator.federationIdentifier is the one required input a Replicator cannot
# read off something they already have. In the common case it IS derivable — it
# is the session name the deploy profile is presenting — so the wizard offers
# that as the prompt default, and says so. These cases pin the three behaviours
# that matter: the right value is offered, a different identity can still be
# typed over it, and a principal with no session name gets NO default rather
# than a confident wrong one.

OPS_SESSION = "operator-session"
OPS_ROLE_ARN = f"arn:aws:sts::{OPS_ID}:assumed-role/OperatorRole/{OPS_SESSION}"

FEDERATION_PROMPT_ANSWERS = [BE_ID, FE_ID, OPS_ID, EMAIL]  # the four before it


def piped(*answers: str) -> str:
    return "".join(f"{answer}\n" for answer in answers)


def test_the_session_name_of_the_deploy_profile_is_offered_as_the_prompt_default(
    repo_factory,
):
    root = make_wizard_repo(repo_factory)
    ops_profile = template_defaults()["ops.profile"]

    # The last answer is an empty line: accept whatever the wizard offered.
    result, calls = run_wizard(
        root,
        stdin=piped(*FEDERATION_PROMPT_ANSWERS, ""),
        stub_account=OPS_ID,
        stub_arn=OPS_ROLE_ARN,
    )

    combined = output(result)
    assert result.returncode == 0, combined
    assert at_path(written(root), "operator.federationIdentifier") == OPS_SESSION
    # The prompt says where the value came from, so nobody has to trust it blind.
    assert f"session name profile {ops_profile} is presenting now" in combined
    # And the wizard itself never prints the caller ARN, which carries an account
    # identifier. (Measured on the wizard's own output, i.e. everything before it
    # hands off to preflight — the recording `aws` stub echoes its canned JSON to
    # stdout for every probe, which is a fixture artifact, not the wizard.)
    wizard_output = result.stdout.split("Handing off to")[0]
    assert OPS_ROLE_ARN not in wizard_output

    # The lookup reuses the one verification call rather than adding a second:
    # three account entries, three calls, one of them the ops profile.
    assert len(calls) == 3, calls
    assert [call for call in calls if f"--profile {ops_profile} " in f"{call} "] != []
    assert len([call for call in calls if f"--profile {ops_profile}" in call]) == 1, calls
    for call in calls:
        assert call.startswith("sts get-caller-identity "), call


def test_a_different_identity_can_be_typed_over_the_offered_session_name(repo_factory):
    """The deploy principal is not always the one that signs in to the web app."""
    root = make_wizard_repo(repo_factory)
    human = "someone-else-session"

    result, _ = run_wizard(
        root,
        stdin=piped(*FEDERATION_PROMPT_ANSWERS, human),
        stub_account=OPS_ID,
        stub_arn=OPS_ROLE_ARN,
    )

    assert result.returncode == 0, output(result)
    assert at_path(written(root), "operator.federationIdentifier") == human


def test_a_principal_with_no_session_name_gets_no_default_and_is_told_why(
    repo_factory,
):
    """An IAM user has no session name, so guessing one would be wrong."""
    root = make_wizard_repo(repo_factory)
    user_arn = f"arn:aws:iam::{OPS_ID}:user/replicator"

    # An empty answer must be REJECTED here — that is the proof no default was
    # offered — and the typed value is what lands in the file.
    result, _ = run_wizard(
        root,
        stdin=piped(*FEDERATION_PROMPT_ANSWERS, "", FEDERATION),
        stub_account=OPS_ID,
        stub_arn=user_arn,
    )

    combined = output(result)
    assert result.returncode == 0, combined
    assert "a value is required" in combined
    assert "no default" in combined
    assert "not authenticating through an assumed role" in combined
    assert at_path(written(root), "operator.federationIdentifier") == FEDERATION


def test_no_verify_offers_no_session_name_and_says_that_is_why(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, calls = run_wizard(
        root,
        "--no-verify",
        stdin=piped(*FEDERATION_PROMPT_ANSWERS, "", FEDERATION),
        stub_account=OPS_ID,
        stub_arn=OPS_ROLE_ARN,
    )

    combined = output(result)
    assert result.returncode == 0, combined
    assert calls == []
    assert "a value is required" in combined
    assert "--no-verify" in combined
    assert at_path(written(root), "operator.federationIdentifier") == FEDERATION


def test_an_existing_federation_identifier_is_preserved_over_the_derived_one(
    repo_factory,
):
    """R11.8 still wins: a re-run is an edit, not a re-derivation."""
    root = make_wizard_repo(repo_factory, config=valid_config())

    result, _ = run_wizard(
        root,
        "--force",
        stdin="\n" * 12,
        stub_account=OPS_ID,
        stub_arn=OPS_ROLE_ARN,
    )

    assert result.returncode == 0, output(result)
    assert at_path(written(root), "operator.federationIdentifier") == FEDERATION


# ─── R11.1, R11.2 — the template drives the prompt set ──────────────────────


def test_a_required_field_added_to_the_template_is_demanded_with_no_script_change(
    repo_factory,
):
    """The key test: the wizard's prompt set lives in the template, not in bash."""
    template = json.loads(REAL_TEMPLATE.read_text())
    template["_doc"]["extra.token"] = {
        "required": True,
        "format": "string",
        "description": "A required input that exists only in this fixture template.",
        "consumedBy": ["a component that does not exist"],
    }
    template["extra"] = {"token": "REPLACE_WITH_TOKEN"}  # nosec B105  # placeholder string in a config-template fixture
    root = make_wizard_repo(repo_factory, template=template)

    # Nobody supplies it: the wizard must demand it by JSON path (R11.19 applied
    # to a field no line of the wizard knows about).
    missing, _ = run_wizard(root, "--non-interactive", "--no-verify", *set_flags(*REQUIRED))
    assert missing.returncode != 0, output(missing)
    assert "extra.token" in output(missing)
    assert not (root / "config" / "accounts.json").exists()

    # Supplied, it is validated and written like any other declared field.
    supplied, _ = run_wizard(
        root,
        "--non-interactive",
        "--no-verify",
        *set_flags(*REQUIRED, "extra.token=a-real-token"),
    )
    assert supplied.returncode == 0, output(supplied)
    assert at_path(written(root), "extra.token") == "a-real-token"

    # And it is prompted for interactively, in template order — last here,
    # so the sixth answer is the one it consumes.
    (root / "config" / "accounts.json").unlink()
    answers = [
        BE_ID,
        FE_ID,
        OPS_ID,
        EMAIL,
        FEDERATION,
        "typed-token",
    ]
    prompted, _ = run_wizard(root, "--no-verify", stdin="".join(f"{a}\n" for a in answers))
    assert prompted.returncode == 0, output(prompted)
    assert "extra.token" in prompted.stdout
    assert at_path(written(root), "extra.token") == "typed-token"


def test_the_wizard_never_prompts_for_an_upstream_fixed_name(repo_factory):
    """R11 deliberately excludes Upstream_Fixed_Names (decision D9)."""
    cluster = "PetsiteECS-cluster"  # the upstream's fixed ECS cluster name
    root = make_wizard_repo(repo_factory)

    result, _ = run_wizard(root, "--non-interactive", "--no-verify", *set_flags(*REQUIRED))

    assert result.returncode == 0, output(result)
    assert cluster not in output(result)
    assert cluster not in (root / "config" / "accounts.json").read_text()


# ─── R11.21 — the identifiers land in exactly one file ──────────────────────


def test_supplied_account_ids_appear_in_no_other_file(repo_factory):
    root = make_wizard_repo(repo_factory)

    result, _ = run_wizard(
        root, "--non-interactive", "--no-verify", *set_flags(*REQUIRED)
    )
    assert result.returncode == 0, output(result)

    target = (root / "config" / "accounts.json").resolve()
    leaked: list[str] = []
    for path in root.rglob("*"):
        if not path.is_file() or path.resolve() == target:
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        if any(account in text for account in (BE_ID, FE_ID, OPS_ID)):
            leaked.append(str(path.relative_to(root)))

    assert leaked == [], f"account identifiers leaked into: {leaked}"
    # And no half-written temporary file survived the atomic write.
    assert not (root / "config" / "accounts.json.tmp").exists()
