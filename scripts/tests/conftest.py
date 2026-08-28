"""Shared fixtures for the shell-library tests under scripts/.

The libraries and scripts in scripts/ are bash; pytest drives them through
subprocess against a throwaway repository laid out in a temp directory. pytest
is already a repository tool, so this adds no dependency (Requirement 10.3).

No 12-digit literal appears in these sources. Account identifiers used by the
fixtures are assembled at runtime by ``fake_account_id`` and ``placeholder_id``
so that a committed test file never carries something a Secret_Scan has to
reason about (Requirement 6.5).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_LIB = REPO_ROOT / "scripts" / "lib" / "config.sh"
REAL_TEMPLATE = REPO_ROOT / "config" / "accounts.json.template"

BASH = shutil.which("bash") or "/bin/bash"

# The bash driver every test runs. It resolves one path, then reports the value,
# the full origin, and the origin level, each on its own line. Resolution
# happens once in the driver's own shell so that a flag-supplied value stays
# reportable; config::get then replays the record.
DRIVER = """#!/usr/bin/env bash
set -euo pipefail
source "${DRIVER_LIB}"
config::init
if [[ "${DRIVER_LEGACY:-0}" == "1" ]]; then
  config::use_legacy_aliases
fi
config::resolve "${DRIVER_PATH}" "${DRIVER_FLAG:-}"
printf 'VALUE=%s\\n' "$(config::get "${DRIVER_PATH}")"
printf 'ORIGIN=%s\\n' "$(config::origin "${DRIVER_PATH}")"
printf 'LEVEL=%s\\n' "$(config::origin_level "${DRIVER_PATH}")"
"""


def fake_account_id(seed: int) -> str:
    """A syntactically valid, obviously unreal 12-digit account identifier.

    Built at runtime from a short seed so the committed source carries no
    12-digit run.
    """
    return f"{seed:012d}"


def placeholder_id(digit: int) -> str:
    """One of the canonical placeholder identifiers, e.g. 1 -> twelve ones."""
    return str(digit) * 12


def make_repo(
    tmp_path: Path,
    template: dict | None = None,
    config: dict | None = None,
    write_config: bool = True,
) -> Path:
    """Lay out a throwaway repo containing the real resolver and JSON fixtures.

    The resolver locates the repository root from its own path, so copying
    scripts/lib/config.sh into ``<root>/scripts/lib/`` is all that is needed for
    it to find ``<root>/config/accounts.json`` and its template.
    """
    root = tmp_path / "repo"
    (root / "scripts" / "lib").mkdir(parents=True)
    (root / "config").mkdir(parents=True)
    shutil.copy2(CONFIG_LIB, root / "scripts" / "lib" / "config.sh")

    template_path = root / "config" / "accounts.json.template"
    if template is None:
        shutil.copy2(REAL_TEMPLATE, template_path)
    else:
        template_path.write_text(json.dumps(template, indent=2) + "\n")

    if write_config:
        (root / "config" / "accounts.json").write_text(
            json.dumps(config if config is not None else {}, indent=2) + "\n"
        )

    driver = root / "scripts" / "driver.sh"
    driver.write_text(DRIVER)
    driver.chmod(0o755)
    return root


def run_driver(
    root: Path,
    path: str,
    flag: str | None = None,
    env: dict[str, str] | None = None,
    legacy: bool = False,
    strip_path: bool = False,
) -> subprocess.CompletedProcess:
    """Run the driver against one JSON path and return the completed process.

    ``strip_path`` empties PATH so that the absent-jq failure mode can be
    exercised without touching the machine's installation.
    """
    child_env = {
        "DRIVER_LIB": str(root / "scripts" / "lib" / "config.sh"),
        "DRIVER_PATH": path,
        "DRIVER_FLAG": flag or "",
        "DRIVER_LEGACY": "1" if legacy else "0",
        "HOME": os.environ.get("HOME", str(root)),
        "PATH": "" if strip_path else os.environ.get("PATH", "/usr/bin:/bin"),
    }
    if env:
        child_env.update(env)
    return subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [BASH, str(root / "scripts" / "driver.sh")],
        env=child_env,
        capture_output=True,
        text=True,
        timeout=60,
    )


def run_snippet(
    root: Path,
    snippet: str,
    env: dict[str, str] | None = None,
    strip_path: bool = False,
) -> subprocess.CompletedProcess:
    """Run an arbitrary bash snippet with the resolver already sourced."""
    script = root / "scripts" / "snippet.sh"
    script.write_text(
        "#!/usr/bin/env bash\nset -euo pipefail\n"
        f'source "{root / "scripts" / "lib" / "config.sh"}"\n' + snippet
    )
    script.chmod(0o755)
    child_env = {
        "HOME": os.environ.get("HOME", str(root)),
        "PATH": "" if strip_path else os.environ.get("PATH", "/usr/bin:/bin"),
    }
    if env:
        child_env.update(env)
    return subprocess.run(  # nosec B603  # test harness runs a repo script with a static argv  # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit
        [BASH, str(script)], env=child_env, capture_output=True, text=True, timeout=60
    )


def reported(result: subprocess.CompletedProcess) -> dict[str, str]:
    """Parse the driver's KEY=value output lines."""
    out: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            out[key] = value
    return out


@pytest.fixture
def repo_factory(tmp_path: Path):
    """Factory building throwaway repos, one per call, under the test's tmp dir."""
    counter = {"n": 0}

    def _make(**kwargs) -> Path:
        counter["n"] += 1
        sub = tmp_path / f"case{counter['n']}"
        sub.mkdir()
        return make_repo(sub, **kwargs)

    return _make
