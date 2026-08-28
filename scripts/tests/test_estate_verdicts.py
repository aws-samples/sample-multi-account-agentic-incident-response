"""Verdict tests for smoke-test.sh and test-fallback.sh.

Both scripts used to report FAIL on a healthy custom estate, for the same
reason: they asserted on an S3 object neither of them caused. These tests pin
the two halves of the fix.

  smoke-test.sh    now CAUSES the thing it asserts on — it invokes each
                   selected fallback agent's `investigate` tool over SigV4 and
                   validates the returned report, then confirms that report
                   reached S3 at the exact key derived from its report_id. So a
                   healthy estate reads PASS, and a missing archive is a real
                   defect rather than an unexercised path.

  test-fallback.sh CANNOT cause what it asserts on — delegation is the
                   responder's choice. An unobserved delegation is therefore
                   INCONCLUSIVE (exit 2), not FAIL; FAIL (exit 1) is reserved
                   for its own precondition breaking.

Each case runs the real script against a throwaway repository holding the real
Config_Resolver and parameter template, with `aws` and `python3` replaced by
recording stubs so no AWS call and no model call happens. The `python3` stub
answers both uses the script makes of it: the urlencode one-liner and the
SigV4 MCP heredoc.

No 12-digit literal appears in this file — identifiers come from
fake_account_id / placeholder_id in conftest.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest

from .conftest import BASH, REPO_ROOT, fake_account_id

SMOKE_TEST = REPO_ROOT / "scripts" / "smoke-test.sh"
TEST_FALLBACK = REPO_ROOT / "scripts" / "test-fallback.sh"

BE_ID = fake_account_id(920_000_000_001)
FE_ID = fake_account_id(920_000_000_002)
OPS_ID = fake_account_id(920_000_000_003)

# A UUID-shaped report id whose last group is not all digits, so the committed
# source carries no 12-digit run for the Secret_Scan to reason about
# (Requirement 6.5, same spirit as conftest's fake_account_id).
REPORT_ID = "11111111-2222-3333-4444-55555555abcd"

# Runtime ARNs the ssm stub hands back. They carry the agent name so the
# python3 stub can tell the two invocations apart from the URL alone.
DEVOPS_RUNTIME = "arn:aws:bedrock-agentcore:us-east-1:{}:runtime/backend_devops_agent-aaa"
KB_RUNTIME = "arn:aws:bedrock-agentcore:us-east-1:{}:runtime/backend_kb_agent-bbb"


def valid_config() -> dict:
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


def report_payload(**overrides) -> dict:
    """A schema-valid report, in the shape the MCP tool returns it."""
    report = {
        "report_id": REPORT_ID,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "status": "completed",
        "trigger": "smoke",
        "skills_enabled": True,
        "business_impact": "Checkout is slow for adopters",
        "root_cause": {
            "fault_id": "checkout-degraded",
            "confidence": "high",
            "description": "documented",
        },
        "evidence_timeline": [],
        "remediation": ["Review the findings"],
        "telemetry": {
            "round_trips": 1,
            "tokens": 100,
            "duration_seconds": 42.0,
            "tool_calls": 2,
        },
    }
    report.update(overrides)
    return {"argument": "symptom", "payload": {"status": "completed", "report": report}}


# ─── Stubs ───────────────────────────────────────────────────────────────────

AWS_STUB = r"""#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "${AWS_CALL_LOG}"

case "$args" in
  *"ssm get-parameter"*"/aiops-poc/webhook-bridge-function"*)
    echo "aiops-poc-webhook-bridge"; exit 0 ;;
  *"ssm get-parameter"*"/aiops-poc/peer"*)
    echo "${STUB_PEER:-both}"; exit 0 ;;
  *"ssm get-parameter"*"/aiops-poc/agents/backend-devops-agent/runtime-arn"*)
    echo "${STUB_DEVOPS_RUNTIME}"; exit 0 ;;
  *"ssm get-parameter"*"/aiops-poc/agents/backend-kb-agent/runtime-arn"*)
    echo "${STUB_KB_RUNTIME}"; exit 0 ;;
  *"ssm get-parameter"*"/aiops-poc/agent-spaces/app-team/arn"*)
    echo "${STUB_SPACE_ARN}"; exit 0 ;;
  *"ssm get-parameter"*"/aiops-poc/agent-spaces/platform/arn"*)
    echo "${STUB_SPACE_ARN}"; exit 0 ;;
  *"lambda invoke"*)
    printf '%s\n' "$args" | tr ' ,' '\n\n' \
      | grep -o 'checkout-latency-p99-diag-test-[0-9]*' | head -1 \
      > "${STUB_ALARM_FILE}" || true
    echo "200"; exit 0 ;;
  *"devops-agent list-backlog-tasks"*)
    if [[ "${STUB_NO_INVESTIGATION:-}" == "1" ]]; then
      echo '{"tasks":[]}'; exit 0
    fi
    alarm="$(cat "${STUB_ALARM_FILE}" 2>/dev/null || echo "none")"
    printf '{"tasks":[{"taskId":"t-1","title":"ALARM: %s","status":"IN_PROGRESS","createdAt":"2026-01-01T00:00:00Z"}]}\n' "$alarm"
    exit 0 ;;
  *"s3api head-object"*)
    if [[ "${STUB_ARCHIVE:-present}" == "present" ]]; then exit 0; fi
    exit 254 ;;
  *"s3api list-objects-v2"*)
    if [[ -n "${STUB_DELEGATED_REPORT:-}" ]]; then
      echo "${STUB_DELEGATED_REPORT}"; exit 0
    fi
    echo "None"; exit 0 ;;
  *"devopsagent update-skill"*)
    exit 252 ;;
esac
exit 0
"""

# The script uses python3 twice: `python3 -c <urlencode> <arg>`, and `python3 -`
# with the SigV4 MCP client on stdin. The stub answers both without importing
# boto3 or reaching the network.
PYTHON_STUB = r"""#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then
  printf '%s\n' "${3:-}"
  exit 0
fi
cat > /dev/null
printf '%s\n' "${URL:-}" >> "${PY_CALL_LOG}"
if [[ -n "${MCP_FAIL_MATCH:-}" && "${URL:-}" == *"${MCP_FAIL_MATCH}"* ]]; then
  echo "stubbed MCP failure for ${URL}" >&2
  exit 1
fi
cat "${MCP_PAYLOAD_FILE}"
"""


def make_repo(repo_factory, script: Path) -> Path:
    root = repo_factory(config=valid_config())
    shutil.copy2(script, root / "scripts" / script.name)
    return root


def run_script(
    root: Path,
    name: str,
    *args: str,
    payload: dict | None = None,
    env: dict[str, str] | None = None,
    timeout: int = 120,
) -> tuple[subprocess.CompletedProcess, str, str]:
    """Run one of the two scripts with recording aws/python3 stubs on PATH.

    Returns the completed process, the recorded aws invocations, and the
    recorded MCP endpoint URLs.
    """
    bindir = root / "stub-bin"
    bindir.mkdir(exist_ok=True)
    for stub_name, body in (("aws", AWS_STUB), ("python3", PYTHON_STUB)):
        stub = bindir / stub_name
        stub.write_text(body)
        stub.chmod(0o755)

    aws_log = root / "aws-calls.log"
    py_log = root / "py-calls.log"
    for log in (aws_log, py_log):
        log.write_text("")

    payload_file = root / "mcp-payload.json"
    payload_file.write_text(json.dumps(payload if payload is not None else report_payload()))

    child_env = {
        "PATH": f"{bindir}:{os.environ.get('PATH', '/usr/bin:/bin')}",
        "HOME": os.environ.get("HOME", str(root)),
        "AWS_CALL_LOG": str(aws_log),
        "PY_CALL_LOG": str(py_log),
        "MCP_PAYLOAD_FILE": str(payload_file),
        "STUB_ALARM_FILE": str(root / "alarm.txt"),
        "STUB_DEVOPS_RUNTIME": DEVOPS_RUNTIME.format(OPS_ID),
        "STUB_KB_RUNTIME": KB_RUNTIME.format(OPS_ID),
        "STUB_SPACE_ARN": f"arn:aws:devops-agent:us-east-1:{OPS_ID}:agent-space/space-1",
    }
    if env:
        child_env.update(env)

    result = subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [BASH, str(root / "scripts" / name), *args],
        env=child_env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return result, aws_log.read_text(), py_log.read_text()


def output(result: subprocess.CompletedProcess) -> str:
    return result.stdout + result.stderr


@pytest.fixture
def smoke_repo(repo_factory) -> Path:
    return make_repo(repo_factory, SMOKE_TEST)


@pytest.fixture
def fallback_repo(repo_factory) -> Path:
    return make_repo(repo_factory, TEST_FALLBACK)


# ─── smoke-test.sh: a healthy estate must read PASS ──────────────────────────


class TestHealthyEstatePasses:
    def test_overall_verdict_is_pass(self, smoke_repo) -> None:
        result, _, _ = run_script(smoke_repo, "smoke-test.sh")

        assert result.returncode == 0, output(result)
        assert "Overall:" in result.stdout
        assert "FAIL" not in result.stdout, output(result)

    def test_both_custom_lines_pass(self, smoke_repo) -> None:
        result, _, _ = run_script(smoke_repo, "smoke-test.sh")

        assert "Custom estate  (investigate → report):     PASS" in result.stdout
        assert "Report archival (S3, by report_id):        PASS" in result.stdout

    def test_every_selected_agent_is_invoked(self, smoke_repo) -> None:
        _, _, py_calls = run_script(smoke_repo, "smoke-test.sh")

        assert "backend_devops_agent" in py_calls
        assert "backend_kb_agent" in py_calls


# ─── smoke-test.sh: the custom check causes what it asserts on ────────────────


class TestCustomCheckIsCausal:
    def test_custom_only_does_not_fire_the_webhook(self, smoke_repo) -> None:
        """The old step 3 depended on an unrelated investigation delegating.
        Nothing about the custom estate needs the webhook now."""
        result, aws_calls, py_calls = run_script(
            smoke_repo, "smoke-test.sh", "--custom-only"
        )

        assert result.returncode == 0, output(result)
        assert "lambda invoke" not in aws_calls
        assert "list-backlog-tasks" not in aws_calls
        assert "backend_devops_agent" in py_calls

    def test_managed_only_invokes_no_agent(self, smoke_repo) -> None:
        result, aws_calls, py_calls = run_script(
            smoke_repo, "smoke-test.sh", "--managed-only"
        )

        assert result.returncode == 0, output(result)
        assert "lambda invoke" in aws_calls
        assert py_calls.strip() == ""

    def test_the_archive_is_checked_at_the_returned_report_id(
        self, smoke_repo
    ) -> None:
        """No timestamp window: the key comes from the report just returned."""
        _, aws_calls, _ = run_script(smoke_repo, "smoke-test.sh", "--custom-only")

        head_calls = [c for c in aws_calls.splitlines() if "head-object" in c]
        assert head_calls, aws_calls
        assert all(f"{REPORT_ID}.json" in c for c in head_calls)
        assert "list-objects-v2" not in aws_calls

    def test_peer_narrows_the_invocation_to_one_agent(self, smoke_repo) -> None:
        _, _, py_calls = run_script(
            smoke_repo, "smoke-test.sh", "--custom-only", "--peer", "devops"
        )

        assert "backend_devops_agent" in py_calls
        assert "backend_kb_agent" not in py_calls

    def test_invalid_peer_is_rejected(self, smoke_repo) -> None:
        result, _, _ = run_script(
            smoke_repo, "smoke-test.sh", "--custom-only", "--peer", "nonsense"
        )

        assert result.returncode == 1
        assert "invalid peer value 'nonsense'" in output(result)


# ─── smoke-test.sh: real defects still FAIL ──────────────────────────────────


class TestRealDefectsStillFail:
    def test_a_failed_invocation_fails_the_custom_estate(self, smoke_repo) -> None:
        result, _, _ = run_script(
            smoke_repo,
            "smoke-test.sh",
            "--custom-only",
            env={"MCP_FAIL_MATCH": "backend_kb_agent"},
        )

        assert result.returncode == 1
        assert "Custom estate  (investigate → report):     FAIL" in result.stdout

    def test_a_missing_archive_fails_only_the_archive_line(self, smoke_repo) -> None:
        """The report came back, so the estate answered — but the archive of a
        report this script caused is genuinely missing."""
        result, _, _ = run_script(
            smoke_repo, "smoke-test.sh", "--custom-only", env={"STUB_ARCHIVE": "absent"}
        )

        assert result.returncode == 1
        assert "Custom estate  (investigate → report):     PASS" in result.stdout
        assert "Report archival (S3, by report_id):        FAIL" in result.stdout
        assert "Archive: MISSING" in result.stdout

    def test_a_schema_invalid_report_fails(self, smoke_repo) -> None:
        broken = report_payload()
        del broken["payload"]["report"]["telemetry"]

        result, _, _ = run_script(
            smoke_repo, "smoke-test.sh", "--custom-only", payload=broken
        )

        assert result.returncode == 1
        assert "MISSING: telemetry" in result.stdout
        assert "Custom estate  (investigate → report):     FAIL" in result.stdout

    def test_a_missing_investigation_fails_the_managed_estate(
        self, smoke_repo
    ) -> None:
        result, _, _ = run_script(
            smoke_repo,
            "smoke-test.sh",
            "--managed-only",
            "--timeout",
            "1",
            env={"STUB_NO_INVESTIGATION": "1"},
        )

        assert result.returncode == 1
        assert "Managed estate (webhook → investigation):  FAIL" in result.stdout


# ─── test-fallback.sh: an unobserved delegation is inconclusive ───────────────


class TestFallbackDelegationVerdicts:
    def test_no_delegated_report_is_inconclusive_not_failed(
        self, fallback_repo
    ) -> None:
        result, _, _ = run_script(
            fallback_repo, "test-fallback.sh", "--timeout", "1"
        )

        assert result.returncode == 2, output(result)
        assert "INCONCLUSIVE" in result.stdout
        assert "FAIL" not in result.stdout, output(result)

    def test_inconclusive_names_the_causal_alternative(self, fallback_repo) -> None:
        result, _, _ = run_script(
            fallback_repo, "test-fallback.sh", "--timeout", "1"
        )

        assert "smoke-test.sh --custom-only" in result.stdout

    def test_a_delegated_report_still_passes(self, fallback_repo) -> None:
        result, _, _ = run_script(
            fallback_repo,
            "test-fallback.sh",
            "--timeout",
            "1",
            env={"STUB_DELEGATED_REPORT": f"reports/2026-01-01/{REPORT_ID}.json"},
        )

        assert result.returncode == 0, output(result)
        assert "PASS" in result.stdout
