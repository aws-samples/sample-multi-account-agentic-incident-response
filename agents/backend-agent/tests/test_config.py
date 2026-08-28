"""Configuration contract tests for the backend agent.

This agent is knowledge-only since the descope, so no stack injects a backend
account into its runtime. The BE_ACCOUNT_ID literal that used to live here was a
dead value, and dead values are exactly how a stale account ID survives into the
next deployment. It is gone, and stays gone.

Validates: Requirements 5.1, 5.2, 5.3
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Ensure src is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import config  # noqa: E402

CONFIG_SOURCE = Path(__file__).resolve().parent.parent / "src" / "config.py"


class TestNoBackendAccount:
    def test_module_exposes_no_backend_account(self) -> None:
        """No BE_ACCOUNT_ID here: nothing populates it and nothing reads it."""
        assert not hasattr(config, "BE_ACCOUNT_ID")

    def test_module_contains_no_twelve_digit_literal(self) -> None:
        source = CONFIG_SOURCE.read_text()
        assert re.search(r"\d{12}", source) is None, (
            "src/config.py must contain no account-ID literal"
        )


class TestEnvironmentDerivedValues:
    def test_region_comes_from_the_environment(self, monkeypatch) -> None:
        import importlib

        monkeypatch.setenv("AWS_REGION", "us-west-2")
        reloaded = importlib.reload(config)
        try:
            assert reloaded.AWS_REGION == "us-west-2"
        finally:
            monkeypatch.undo()
            importlib.reload(config)
