"""Repository hygiene assertions — the ignore rules that keep account IDs local.

Unlike the rest of scripts/tests, these run against *this* repository rather
than a temp fixture: the property under test is a fact about the real index and
the real .gitignore, so a synthetic repo could not observe it. Everything here
is a read-only ``git`` query driven through subprocess, matching the suite's
convention of exercising the real tooling.

Requirements: 7.1, 7.2, 6.4
"""

from __future__ import annotations

import shutil
import subprocess

import pytest

from .conftest import REPO_ROOT

GIT = shutil.which("git") or "/usr/bin/git"

# Paths that must stay out of version control because they carry, or resolve to,
# real account identifiers. Each is git-ignored rather than merely absent.
IGNORED_PATHS = [
    "config/accounts.json",
    "AWS Credentials Prompt.md",
    "cdk.context.json",
    "agents/infra/cdk.context.json",
    "workload/backend/overlay/cdk.context.json",
    "workload/frontend/cdk.context.json",
    # Working spec documents are local to the author; the machine-written
    # tasks.meta.json also carries epoch timestamps that read like account ids.
    ".kiro/specs/ai-ops-a2a-poc/tasks.md",
    ".kiro/specs/centralized-parameters/tasks.meta.json",
    # Personal steering notes (credential workflow, profile mappings) are the
    # author's local Kiro configuration, not repository content.
    ".kiro/steering/aws-deployment.md",
]


def git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [GIT, "-C", str(REPO_ROOT), *args],
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_no_cdk_context_file_is_tracked() -> None:
    """Requirement 7.1, 7.2 — the lookup caches are untracked at every depth."""
    tracked = [
        line
        for line in git("ls-files").stdout.splitlines()
        if line.endswith("cdk.context.json")
    ]

    assert tracked == [], (
        "cdk.context.json holds environment-specific account/VPC/subnet/AZ "
        f"lookups and must not be committed: {tracked}"
    )


@pytest.mark.parametrize("path", IGNORED_PATHS)
def test_path_is_git_ignored(path: str) -> None:
    """Requirement 6.4, 7.1 — the ignore rule covers the path, not just its absence."""
    result = git("check-ignore", "-v", "--no-index", "--", path)

    assert result.returncode == 0, (
        f"{path} is not matched by any .gitignore rule: "
        f"{result.stdout}{result.stderr}"
    )
    assert ".gitignore" in result.stdout


def test_no_kiro_file_is_tracked() -> None:
    """.kiro/ is the author's local Kiro workspace — specs and steering alike.

    The steering file carries the author's personal credential workflow and
    profile mappings, so it must stay out of version control entirely.
    """
    tracked = [
        line
        for line in git("ls-files").stdout.splitlines()
        if line.startswith(".kiro/")
    ]

    assert tracked == [], (
        "'.kiro/' holds working documents local to the author "
        f"and must not be committed: {tracked}"
    )


def test_cdk_context_rule_is_depth_independent() -> None:
    """A nested app added later is ignored without touching .gitignore."""
    nested = "some/future/app/cdk.context.json"

    result = git("check-ignore", "-v", "--no-index", "--", nested)

    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip().endswith(nested)
