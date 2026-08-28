"""Tests for the two build-time guards in workload/backend/deploy/deploy-upstream.sh.

**The build cap.** `aws cloudformation deploy` sends `UsePreviousValue` for every
parameter absent from `--parameter-overrides`, so a stack first created with a
60-minute `BuildTimeoutMinutes` keeps 60 forever and raising the template's
default is a silent no-op on the re-run — the exact run that needs it, having
just been timed out. The fix is only a fix if the parameter is passed on *every*
run, which is what these cases assert, along with the local bounds check that
refuses a bad `--timeout-minutes` before anything is deployed.

**The image assertion.** The upstream ECS services pull `:latest` from ECR, and a
failed `Build-<service>` action in upstream's own pipeline presents as
`DevMicroservicesStack` sitting in `CREATE_IN_PROGRESS` for ~45 minutes. The
script asserts the tags after the build and names the empty repository, the failed
action and the retry command. The expected repository set is *derived* from the
pipeline's own Build-stage actions, which is why the fixture pipeline below
publishes invented service names: a hardcoded list could not pass these cases.

Each case runs the real script against a throwaway repository holding the real
Config_Resolver, with `aws` replaced by a recording stub that answers the way each
API would. No AWS call is made, and no 12-digit literal appears in this file —
identifiers come from ``fake_account_id`` in conftest (Requirement 6.5).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

from .conftest import BASH, REPO_ROOT, fake_account_id

DEPLOY_DIR = REPO_ROOT / "workload" / "backend" / "deploy"
DEPLOY_UPSTREAM = DEPLOY_DIR / "deploy-upstream.sh"
CFN_TEMPLATE = DEPLOY_DIR / "cfn-codebuild-stack.yaml"

BE_ID = fake_account_id(930_000_000_001)
FE_ID = fake_account_id(930_000_000_002)
OPS_ID = fake_account_id(930_000_000_003)

# The script's own default, and the template's MinValue/MaxValue.
DEFAULT_TIMEOUT = 120
MIN_TIMEOUT = 10
MAX_TIMEOUT = 2160

PIPELINE = "DevApplicationsStack-pipeline"

# Invented service names: the expected repository set is read out of the pipeline,
# so these have to flow through unchanged for the check to work at all.
TARGETS = "svc-alpha\tlatest\nsvc-beta\tlatest\n"

FAILED_STATE = json.dumps(
    {
        "stageStates": [
            {
                "stageName": "Build",
                "latestExecution": {
                    "pipelineExecutionId": "exec-id-under-test",
                    "status": "Failed",
                },
                "actionStates": [
                    {
                        "actionName": "Build-svc-beta",
                        "latestExecution": {
                            "status": "Failed",
                            "errorDetails": {"message": "upstream said 502"},
                        },
                    },
                    {
                        "actionName": "Build-svc-alpha",
                        "latestExecution": {"status": "Succeeded"},
                    },
                ],
            }
        ]
    }
)

# One stub for every AWS call the script can make on these paths. It records the
# full argument list, so "passed the parameter" is verified rather than assumed.
AWS_STUB = r"""#!/usr/bin/env bash
printf '%s\n' "aws $*" >> "${CALL_LOG}"

repo_name=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--repository-name" ]]; then
    repo_name="$arg"
  fi
  prev="$arg"
done

case "$1 $2" in
  "cloudformation deploy")         exit 0 ;;
  "cloudformation describe-stacks") printf '%s\n' "aiops-poc-upstream-backend"; exit 0 ;;
  "codebuild start-build")         printf '%s\n' "build-id-under-test"; exit 0 ;;
  "codebuild batch-get-builds")    printf '%s\n' "${BUILD_STATUS_ANSWER}"; exit 0 ;;
  "codepipeline get-pipeline")     printf '%s' "${PIPELINE_TARGETS}"; exit 0 ;;
  "codepipeline get-pipeline-state") printf '%s\n' "${PIPELINE_STATE}"; exit 0 ;;
  "lambda invoke")
    # The seeding that follows a successful build: answer it so the post-build
    # path is reached quickly. The only absolute path in the argument list is the
    # response file the script passes positionally.
    for arg in "$@"; do
      case "$arg" in
        /*) printf '%s' '{"statusCode": 200}' > "$arg" ;;
      esac
    done
    printf '%s\n' "200"
    exit 0 ;;
  "ecr list-images")
    case " ${ECR_TAGGED} " in
      *" ${repo_name} "*) printf '%s\n' "latest" ;;
      *)                  printf '%s\n' "None" ;;
    esac
    exit 0 ;;
esac
exit 0
"""


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


def run_deploy(
    repo_factory,
    *args: str,
    build_status: str = "SUCCEEDED",
    ecr_tagged: str = "svc-alpha svc-beta",
    pipeline_targets: str = TARGETS,
    pipeline_state: str = FAILED_STATE,
) -> tuple[subprocess.CompletedProcess, list[str]]:
    """Run deploy-upstream.sh with a stub `aws` first on PATH."""
    root = repo_factory(config=config_json())
    deploy_dir = root / "workload" / "backend" / "deploy"
    deploy_dir.mkdir(parents=True)
    shutil.copy2(DEPLOY_UPSTREAM, deploy_dir / "deploy-upstream.sh")
    shutil.copy2(CFN_TEMPLATE, deploy_dir / "cfn-codebuild-stack.yaml")

    bindir = root / "stub-bin"
    bindir.mkdir(exist_ok=True)
    stub = bindir / "aws"
    stub.write_text(AWS_STUB)
    stub.chmod(0o755)

    call_log = root / "calls.log"
    env = {
        "PATH": f"{bindir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
        "HOME": os.environ.get("HOME", str(root)),
        "CALL_LOG": str(call_log),
        "BUILD_STATUS_ANSWER": build_status,
        "ECR_TAGGED": ecr_tagged,
        "PIPELINE_TARGETS": pipeline_targets,
        "PIPELINE_STATE": pipeline_state,
    }
    result = subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [BASH, str(deploy_dir / "deploy-upstream.sh"), *args],
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )
    calls = call_log.read_text().splitlines() if call_log.exists() else []
    return result, calls


def output(result: subprocess.CompletedProcess) -> str:
    return result.stdout + result.stderr


def deploy_calls(calls: list[str]) -> list[str]:
    return [c for c in calls if c.startswith("aws cloudformation deploy")]


# ─── The build cap is passed, not inherited ──────────────────────────────────


def test_build_timeout_is_passed_on_every_run(repo_factory) -> None:
    """Absent from --parameter-overrides means UsePreviousValue, i.e. inherited."""
    result, calls = run_deploy(repo_factory)

    assert result.returncode == 0, output(result)
    assert len(deploy_calls(calls)) == 1, calls
    assert f"BuildTimeoutMinutes={DEFAULT_TIMEOUT}" in deploy_calls(calls)[0]
    # The other four overrides are still there.
    for name in ("UpstreamRepoUrl", "UpstreamRef", "UpstreamOrg", "UpstreamRepo"):
        assert f"{name}=" in deploy_calls(calls)[0]


def test_timeout_flag_overrides_the_default(repo_factory) -> None:
    result, calls = run_deploy(repo_factory, "--timeout-minutes", "180")

    assert result.returncode == 0, output(result)
    assert "BuildTimeoutMinutes=180" in deploy_calls(calls)[0]
    assert f"BuildTimeoutMinutes={DEFAULT_TIMEOUT}" not in deploy_calls(calls)[0]
    # And the run says which cap it is deploying with.
    assert "180 minutes" in result.stdout


def test_the_default_matches_the_template_default(repo_factory) -> None:
    """A script default below the template's would silently lower a stack's cap."""
    template = CFN_TEMPLATE.read_text()
    block = template.split("BuildTimeoutMinutes:", 1)[1]
    assert f"Default: {DEFAULT_TIMEOUT}" in block
    assert f"MinValue: {MIN_TIMEOUT}" in block
    assert f"MaxValue: {MAX_TIMEOUT}" in block


# ─── The flag is validated locally, against the template's own bounds ────────


def test_timeout_below_the_minimum_is_refused_before_deploying(repo_factory) -> None:
    result, calls = run_deploy(repo_factory, "--timeout-minutes", str(MIN_TIMEOUT - 1))

    assert result.returncode == 1, output(result)
    assert deploy_calls(calls) == [], "refused, yet the stack was still deployed"
    assert calls == [], "refused, yet an AWS call was still made"
    assert f"{MIN_TIMEOUT}-{MAX_TIMEOUT}" in result.stderr
    assert "Nothing was deployed" in result.stderr


def test_timeout_above_the_maximum_is_refused(repo_factory) -> None:
    result, calls = run_deploy(repo_factory, "--timeout-minutes", str(MAX_TIMEOUT + 1))

    assert result.returncode == 1, output(result)
    assert calls == [], calls
    assert f"{MAX_TIMEOUT}" in result.stderr


def test_non_numeric_timeout_is_refused_naming_the_range(repo_factory) -> None:
    result, calls = run_deploy(repo_factory, "--timeout-minutes", "two hours")

    assert result.returncode == 1, output(result)
    assert calls == [], calls
    assert "whole number of minutes" in result.stderr
    assert f"{MIN_TIMEOUT}-{MAX_TIMEOUT}" in result.stderr


def test_the_bounds_are_accepted_at_the_edges(repo_factory) -> None:
    for value in (MIN_TIMEOUT, MAX_TIMEOUT):
        result, calls = run_deploy(repo_factory, "--timeout-minutes", str(value))
        assert result.returncode == 0, output(result)
        assert f"BuildTimeoutMinutes={value}" in deploy_calls(calls)[0]


# ─── The image assertion ─────────────────────────────────────────────────────
#
# Run on the failing-build path: it reaches the assertion without the seeding that
# follows a successful build, and it is the path where a replicator actually met
# this failure (a build killed at 60 minutes while a stack waited on an image).


def test_missing_image_names_the_repository_action_and_retry(repo_factory) -> None:
    result, calls = run_deploy(
        repo_factory, "--wait", build_status="FAILED", ecr_tagged="svc-alpha"
    )

    message = output(result)
    # The build failure owns the exit status; the check only adds the cause.
    assert result.returncode == 1, message
    # Which repository is empty, and which is not.
    assert "svc-beta:latest" in message
    assert "svc-alpha:latest" in message
    # The upstream pipeline action that failed, with upstream's own error text.
    assert "Build-svc-beta" in message
    assert "upstream said 502" in message
    # The recovery command, with the execution id already filled in.
    assert "retry-stage-execution" in message
    assert "--pipeline-execution-id exec-id-under-test" in message
    assert "--retry-mode FAILED_ACTIONS" in message
    # And what the symptom will look like if it is ignored.
    assert "CannotPullContainerError" in message
    assert "DevMicroservicesStack" in message
    # Read-only throughout: no mutating call was made.
    for call in calls:
        assert "retry-stage-execution" not in call
        assert "batch-delete-image" not in call


def test_the_expected_repository_set_comes_from_the_pipeline(repo_factory) -> None:
    """Not a hardcoded list: rename the services and the check follows."""
    result, calls = run_deploy(
        repo_factory,
        "--wait",
        build_status="FAILED",
        pipeline_targets="svc-gamma\tlatest\n",
        ecr_tagged="",
    )

    message = output(result)
    assert "svc-gamma:latest" in message
    assert "svc-alpha" not in message
    checked = [c for c in calls if c.startswith("aws ecr list-images")]
    assert len(checked) == 1, checked
    assert "--repository-name svc-gamma" in checked[0]


def test_all_images_present_warns_about_nothing(repo_factory) -> None:
    result, _ = run_deploy(repo_factory, "--wait", build_status="FAILED")

    message = output(result)
    assert result.returncode == 1, message
    assert "all 2 upstream application image(s) present" in result.stdout
    assert "retry-stage-execution" not in message
    assert "INCOMPLETE" not in message


def test_an_unreadable_pipeline_skips_the_check_rather_than_guessing(
    repo_factory,
) -> None:
    """No pipeline, no expected set — and no invented list to assert against."""
    result, calls = run_deploy(
        repo_factory, "--wait", build_status="FAILED", pipeline_targets=""
    )

    message = output(result)
    assert result.returncode == 1, message
    assert "skipping the image check" in message
    assert [c for c in calls if c.startswith("aws ecr list-images")] == []
    assert "INCOMPLETE" not in message


def test_a_successful_build_also_asserts_the_images(repo_factory) -> None:
    """The check is not only a failure-path diagnostic."""
    result, calls = run_deploy(repo_factory, "--wait", build_status="SUCCEEDED")

    # Seeding follows on this path and is not stubbed to succeed, so the exit
    # status is not what is under test here — the ECR reads are.
    checked = [c for c in calls if c.startswith("aws ecr list-images")]
    assert len(checked) == 2, checked
    assert "all 2 upstream application image(s) present" in output(result)
