"""Config_Resolver precedence: flag > env > file > template default.

All 16 combinations of the four sources being present or absent are enumerated,
and each asserts both the resolved value and the reported origin. The precedence
rule is a pure function of four booleans, so enumerating the domain is stronger
than sampling it.

The field under test carries a template default in the eight cases where the
default source is present, and is a required field with no declared default in
the eight where it is absent.

Requirements: 2.1, 2.5
"""

from __future__ import annotations

import itertools

import pytest

from .conftest import reported, run_driver, run_snippet

# A fixture template rather than the real one: the matrix needs one field that
# declares a default and one that declares none, which the real surface does not
# offer for the same JSON path.
FIXTURE_TEMPLATE = {
    "_doc": {
        "$": "Fixture template for the Config_Resolver precedence tests.",
        "demo.withDefault": {
            "required": False,
            "default": "template-default",
            "format": "string",
            "description": "Optional demo field carrying a template default.",
            "consumedBy": ["scripts/tests"],
        },
        "demo.noDefault": {
            "required": True,
            "format": "string",
            "description": "Required demo field with no template default.",
            "consumedBy": ["scripts/tests"],
        },
    },
    "demo": {
        "withDefault": "template-default",
        "noDefault": "REPLACE_WITH_DEMO_VALUE",
    },
}

FLAG_VALUE = "flag-value"
ENV_VALUE = "env-value"
FILE_VALUE = "file-value"
DEFAULT_VALUE = "template-default"


def _case_id(flag: bool, env: bool, file_: bool, default: bool) -> str:
    present = [
        name
        for name, on in (("flag", flag), ("env", env), ("file", file_), ("default", default))
        if on
    ]
    return "+".join(present) if present else "none"


_MATRIX = list(itertools.product([False, True], repeat=4))


@pytest.mark.parametrize(
    "flag,env,file_,default",
    _MATRIX,
    ids=[_case_id(*combo) for combo in _MATRIX],
)
def test_precedence_matrix(repo_factory, flag, env, file_, default):
    """The highest-precedence present source supplies the value and the origin."""
    path = "demo.withDefault" if default else "demo.noDefault"
    leaf = path.split(".")[1]
    env_name = f"AIOPS_DEMO_{leaf.upper()}"

    config: dict = {"demo": {}}
    if file_:
        config["demo"][leaf] = FILE_VALUE

    root = repo_factory(template=FIXTURE_TEMPLATE, config=config)
    result = run_driver(
        root,
        path,
        flag=FLAG_VALUE if flag else None,
        env={env_name: ENV_VALUE} if env else None,
    )

    case = _case_id(flag, env, file_, default)

    if not (flag or env or file_ or default):
        assert result.returncode != 0, f"[{case}] expected a non-zero exit"
        assert path in result.stderr, f"[{case}] stderr must name the JSON path"
        return

    assert result.returncode == 0, f"[{case}] {result.stderr}"
    values = reported(result)

    if flag:
        expected_value, expected_level, expected_detail = FLAG_VALUE, "flag", "command line"
    elif env:
        expected_value, expected_level, expected_detail = ENV_VALUE, "env", env_name
    elif file_:
        expected_value, expected_level, expected_detail = (
            FILE_VALUE,
            "file",
            "config/accounts.json",
        )
    else:
        expected_value, expected_level, expected_detail = DEFAULT_VALUE, "default", "template"

    assert values["VALUE"] == expected_value, f"[{case}] wrong value"
    assert values["LEVEL"] == expected_level, f"[{case}] wrong precedence level"
    assert values["ORIGIN"] == f"{expected_level} ({expected_detail})", f"[{case}] wrong origin"


def test_account_triple_is_exported_and_honours_flags(repo_factory):
    """config::account exports the triple and applies flag precedence to it."""
    # The real template is the fixture here: the account triple is part of the
    # declared surface, so nothing synthetic is needed.
    root = repo_factory(
        config={
            "backend": {
                "accountId": f"{4242:012d}",
                "region": "region-from-file",
                "profile": "profile-from-file",
            },
            "frontend": {
                "accountId": f"{4243:012d}",
                "region": "region-from-file",
                "profile": "profile-from-file",
            },
            "ops": {
                "accountId": f"{4244:012d}",
                "region": "region-from-file",
                "profile": "profile-from-file",
                "escalationEmail": "ops@example.test",
            },
            "operator": {"federationIdentifier": "fixture-federation"},
        }
    )

    result = run_snippet(
        root,
        "\n".join(
            [
                "config::init",
                "config::account be",
                'printf "ACCOUNT=%s\\n" "$CONFIG_BE_ACCOUNT"',
                'printf "REGION=%s\\n" "$CONFIG_BE_REGION"',
                'printf "PROFILE=%s\\n" "$CONFIG_BE_PROFILE"',
                "config::account fe --profile-flag profile-from-flag --region-flag region-from-flag",
                'printf "FE_PROFILE=%s\\n" "$CONFIG_FE_PROFILE"',
                'printf "FE_REGION=%s\\n" "$CONFIG_FE_REGION"',
                'printf "FE_PROFILE_ORIGIN=%s\\n" "$(config::origin frontend.profile)"',
            ]
        ),
    )

    assert result.returncode == 0, result.stderr
    values = reported(result)
    assert values["ACCOUNT"] == f"{4242:012d}"
    assert values["REGION"] == "region-from-file"
    assert values["PROFILE"] == "profile-from-file"
    assert values["FE_PROFILE"] == "profile-from-flag"
    assert values["FE_REGION"] == "region-from-flag"
    assert values["FE_PROFILE_ORIGIN"] == "flag (command line)"
