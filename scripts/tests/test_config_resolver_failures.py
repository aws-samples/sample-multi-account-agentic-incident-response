"""Config_Resolver failure paths, template defaults, and legacy env aliases.

Every failure must be non-zero and must name either the JSON path or the missing
prerequisite, and every diagnostic must land on stderr so that command
substitution around config::get stays clean.

Requirements: 3.1, 3.2, 3.3, 3.4, 3.6, 10.2
"""

from __future__ import annotations

import json
import os

from .conftest import fake_account_id, placeholder_id, reported, run_driver, run_snippet


def valid_config(**overrides) -> dict:
    """A configuration that satisfies every required field of the real template."""
    config = {
        "backend": {
            "accountId": fake_account_id(4242),
            "region": "us-east-1",
            "profile": "be-fixture-profile",
        },
        "frontend": {
            "accountId": fake_account_id(4243),
            "region": "us-east-1",
            "profile": "fe-fixture-profile",
        },
        "ops": {
            "accountId": fake_account_id(4244),
            "region": "us-east-1",
            "profile": "ops-fixture-profile",
            "escalationEmail": "ops@example.test",
        },
        "operator": {"federationIdentifier": "fixture-federation"},
    }
    for key, value in overrides.items():
        config[key] = value
    return config


# ─── Missing prerequisites and missing files (R3.1, R3.4) ────────────────────


def test_absent_jq_names_jq_as_the_missing_prerequisite(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_driver(root, "ops.region", strip_path=True)

    assert result.returncode != 0
    assert "jq" in result.stderr
    assert result.stdout == ""


def test_missing_config_file_names_both_paths_and_the_cp_command(repo_factory):
    root = repo_factory(write_config=False)
    result = run_driver(root, "ops.region")

    assert result.returncode != 0
    assert "config/accounts.json" in result.stderr
    assert "config/accounts.json.template" in result.stderr
    assert "cp config/accounts.json.template config/accounts.json" in result.stderr
    assert result.stdout == ""


def test_missing_template_names_the_template(repo_factory):
    root = repo_factory(config=valid_config())
    (root / "config" / "accounts.json.template").unlink()
    result = run_driver(root, "ops.region")

    assert result.returncode != 0
    assert "config/accounts.json.template" in result.stderr


# ─── Missing and placeholder values (R3.2, R3.3) ─────────────────────────────


def test_missing_required_field_names_its_json_path(repo_factory):
    config = valid_config()
    del config["ops"]["escalationEmail"]
    root = repo_factory(config=config)
    result = run_driver(root, "ops.escalationEmail")

    assert result.returncode != 0
    assert "ops.escalationEmail" in result.stderr
    assert result.stdout == ""


def test_placeholder_account_id_is_rejected_with_path_and_value(repo_factory):
    placeholder = placeholder_id(1)
    config = valid_config()
    config["backend"]["accountId"] = placeholder
    root = repo_factory(config=config)
    result = run_driver(root, "backend.accountId")

    assert result.returncode != 0
    assert "backend.accountId" in result.stderr
    assert placeholder in result.stderr
    assert result.stdout == ""


def test_placeholder_prefixed_value_is_rejected(repo_factory):
    config = valid_config()
    config["ops"]["escalationEmail"] = "REPLACE_WITH_TEAM_EMAIL"
    root = repo_factory(config=config)
    result = run_driver(root, "ops.escalationEmail")

    assert result.returncode != 0
    assert "ops.escalationEmail" in result.stderr
    assert "REPLACE_WITH_TEAM_EMAIL" in result.stderr


def test_value_still_equal_to_the_template_is_a_placeholder(repo_factory):
    """A template placeholder outside the known patterns is still caught.

    The rule compares against the template's own value for the same path, for
    the formats where a real configuration can never legitimately repeat it.
    """
    template_placeholder = fake_account_id(9999)
    template = {
        "_doc": {
            "$": "Fixture template with a non-canonical placeholder identifier.",
            "demo.accountId": {
                "required": True,
                "format": "accountId",
                "description": "Demo account identifier.",
                "consumedBy": ["scripts/tests"],
            },
        },
        "demo": {"accountId": template_placeholder},
    }
    root = repo_factory(template=template, config={"demo": {"accountId": template_placeholder}})
    result = run_driver(root, "demo.accountId")

    assert result.returncode != 0
    assert "demo.accountId" in result.stderr

    # A real identifier for the same field resolves normally.
    root_ok = repo_factory(template=template, config={"demo": {"accountId": fake_account_id(4242)}})
    ok = run_driver(root_ok, "demo.accountId")
    assert ok.returncode == 0, ok.stderr
    assert reported(ok)["VALUE"] == fake_account_id(4242)


def test_undeclared_path_fails_naming_the_template(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_driver(root, "ops.notAField")

    assert result.returncode != 0
    assert "ops.notAField" in result.stderr
    assert "config/accounts.json.template" in result.stderr


# ─── Declared format and enum domain (R3.2, R3.3) ────────────────────────────
# A hand-edited config/accounts.json reaches the resolver without ever passing
# through the Setup_Wizard, so the resolver applies the same format / allowed
# rules the wizard applies at entry time. Kept in step with the loader cases in
# agents/infra/test/accounts-config.test.ts.


def test_account_id_one_digit_short_is_rejected_naming_the_path(repo_factory):
    short_id = fake_account_id(4242)[:-1]
    config = valid_config()
    config["backend"]["accountId"] = short_id
    root = repo_factory(config=config)
    result = run_driver(root, "backend.accountId")

    assert result.returncode != 0
    assert "backend.accountId" in result.stderr
    assert short_id in result.stderr
    assert "12" in result.stderr
    assert result.stdout == ""


def test_account_id_one_digit_too_long_is_rejected_naming_the_path(repo_factory):
    long_id = fake_account_id(4242) + "7"
    config = valid_config()
    config["ops"]["accountId"] = long_id
    root = repo_factory(config=config)
    result = run_driver(root, "ops.accountId")

    assert result.returncode != 0
    assert "ops.accountId" in result.stderr
    assert long_id in result.stderr


def test_malformed_email_is_rejected_naming_the_path(repo_factory):
    config = valid_config()
    config["ops"]["escalationEmail"] = "ops-team.example.test"
    root = repo_factory(config=config)
    result = run_driver(root, "ops.escalationEmail")

    assert result.returncode != 0
    assert "ops.escalationEmail" in result.stderr
    assert "ops-team.example.test" in result.stderr
    assert "email" in result.stderr


def test_out_of_domain_enum_is_rejected_listing_the_allowed_values(repo_factory):
    root = repo_factory(config=valid_config(peer="nonsense"))
    result = run_driver(root, "peer")

    assert result.returncode != 0
    assert "peer" in result.stderr
    assert "nonsense" in result.stderr
    template = json.loads((root / "config" / "accounts.json.template").read_text())
    for allowed in template["_doc"]["peer"]["allowed"]:
        assert allowed in result.stderr


def test_valid_enum_value_from_the_config_file_is_accepted(repo_factory):
    root = repo_factory(config=valid_config(peer="devops"))
    result = run_driver(root, "peer")

    assert result.returncode == 0, result.stderr
    values = reported(result)
    assert values["VALUE"] == "devops"
    assert values["ORIGIN"] == "file (config/accounts.json)"


def test_out_of_domain_enum_from_the_environment_is_rejected(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_driver(root, "escalation.mode", env={"AIOPS_ESCALATION_MODE": "whenever"})

    assert result.returncode != 0
    assert "escalation.mode" in result.stderr
    assert "whenever" in result.stderr
    assert "always" in result.stderr and "auto" in result.stderr


def test_a_region_this_repo_has_never_used_is_accepted(repo_factory):
    """No region allowlist: a region AWS adds must resolve without a code change."""
    config = valid_config()
    config["ops"]["region"] = "ap-northeast-3"
    root = repo_factory(config=config)
    result = run_driver(root, "ops.region")

    assert result.returncode == 0, result.stderr
    values = reported(result)
    assert values["VALUE"] == "ap-northeast-3"
    assert values["ORIGIN"] == "file (config/accounts.json)"


def test_whitespace_only_string_is_rejected_naming_the_path(repo_factory):
    config = valid_config()
    config["operator"]["federationIdentifier"] = "   "
    root = repo_factory(config=config)
    result = run_driver(root, "operator.federationIdentifier")

    assert result.returncode != 0
    assert "operator.federationIdentifier" in result.stderr


def test_non_boolean_for_a_boolean_field_is_rejected(repo_factory):
    root = repo_factory(config=valid_config(skillsEnabled="yes"))
    result = run_driver(root, "skillsEnabled")

    assert result.returncode != 0
    assert "skillsEnabled" in result.stderr
    assert "true or false" in result.stderr


# ─── Template defaults (R3.6) ────────────────────────────────────────────────


def test_optional_field_absent_from_config_uses_the_template_default(repo_factory):
    config = valid_config()
    del config["ops"]["region"]
    root = repo_factory(config=config)
    result = run_driver(root, "ops.region")

    assert result.returncode == 0, result.stderr
    values = reported(result)
    template = json.loads((root / "config" / "accounts.json.template").read_text())
    assert values["VALUE"] == template["_doc"]["ops.region"]["default"]
    assert values["ORIGIN"] == "default (template)"
    assert values["LEVEL"] == "default"


def test_optional_field_absent_entirely_still_reports_default(repo_factory):
    """A field the config file never mentions at all, not just an empty value."""
    root = repo_factory(config=valid_config())
    result = run_driver(root, "escalation.mode")

    assert result.returncode == 0, result.stderr
    assert reported(result)["ORIGIN"] == "default (template)"


# ─── Legacy environment aliases (R10.2) ──────────────────────────────────────


def test_legacy_profile_alias_resolves_at_env_precedence(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_driver(
        root, "backend.profile", env={"PROFILE": "legacy-profile"}, legacy=True
    )

    assert result.returncode == 0, result.stderr
    values = reported(result)
    assert values["VALUE"] == "legacy-profile"
    assert values["ORIGIN"] == "env (PROFILE)"


def test_legacy_region_alias_resolves_at_env_precedence(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_driver(root, "ops.region", env={"REGION": "legacy-region"}, legacy=True)

    assert result.returncode == 0, result.stderr
    values = reported(result)
    assert values["VALUE"] == "legacy-region"
    assert values["ORIGIN"] == "env (REGION)"


def test_legacy_alias_is_ignored_without_the_per_script_opt_in(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_driver(root, "backend.profile", env={"PROFILE": "legacy-profile"})

    assert result.returncode == 0, result.stderr
    values = reported(result)
    assert values["VALUE"] == "be-fixture-profile"
    assert values["ORIGIN"] == "file (config/accounts.json)"


def test_canonical_env_name_beats_the_legacy_alias(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_driver(
        root,
        "backend.profile",
        env={"PROFILE": "legacy-profile", "AIOPS_BACKEND_PROFILE": "canonical-profile"},
        legacy=True,
    )

    assert result.returncode == 0, result.stderr
    values = reported(result)
    assert values["VALUE"] == "canonical-profile"
    assert values["ORIGIN"] == "env (AIOPS_BACKEND_PROFILE)"


def test_flag_beats_the_legacy_alias(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_driver(
        root, "ops.region", flag="region-from-flag", env={"REGION": "legacy-region"}, legacy=True
    )

    assert result.returncode == 0, result.stderr
    assert reported(result)["VALUE"] == "region-from-flag"


# ─── Reporting surface ───────────────────────────────────────────────────────


def test_dump_reports_every_declared_path_with_its_origin(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_snippet(root, "config::init\nconfig::dump\n")

    assert result.returncode == 0, result.stderr
    template = json.loads((root / "config" / "accounts.json.template").read_text())
    declared = [key for key in template["_doc"] if key != "$"]
    for path in declared:
        assert path in result.stdout, f"{path} missing from the dump"
    assert "default (template)" in result.stdout
    assert "file (config/accounts.json)" in result.stdout


def test_dump_lists_every_problem_and_exits_non_zero(repo_factory):
    config = valid_config()
    del config["ops"]["escalationEmail"]
    config["backend"]["accountId"] = placeholder_id(1)
    root = repo_factory(config=config)
    result = run_snippet(root, "config::init\nconfig::dump --redact\n")

    assert result.returncode != 0
    assert "MISSING" in result.stdout
    assert "PLACEHOLDER" in result.stdout
    assert "ops.escalationEmail" in result.stdout
    assert "backend.accountId" in result.stdout
    # --redact keeps identifiers out of the report except for the last four digits
    assert fake_account_id(4243) not in result.stdout


def test_aws_helper_passes_the_resolved_profile_and_region(repo_factory):
    """config::aws invokes the CLI with the triple resolved for that account."""
    root = repo_factory(config=valid_config())
    stub_dir = root / "stub-bin"
    stub_dir.mkdir()
    stub = stub_dir / "aws"
    stub.write_text('#!/usr/bin/env bash\nprintf "AWS_ARGS=%s\\n" "$*"\n')
    stub.chmod(0o755)

    result = run_snippet(
        root,
        "config::init\nconfig::aws ops -- sts get-caller-identity\n",
        env={"PATH": f"{stub_dir}:{os.environ.get('PATH', '/usr/bin:/bin')}"},
    )

    assert result.returncode == 0, result.stderr
    assert reported(result)["AWS_ARGS"] == (
        "--profile ops-fixture-profile --region us-east-1 sts get-caller-identity"
    )


def test_successful_get_writes_only_the_value_to_stdout(repo_factory):
    root = repo_factory(config=valid_config())
    result = run_snippet(root, 'config::init\nconfig::get ops.region\n')

    assert result.returncode == 0, result.stderr
    assert result.stdout == "us-east-1\n"
