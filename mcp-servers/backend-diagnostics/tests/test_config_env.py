"""Environment-contract tests for the diagnostics MCP configuration.

The diagnostics MCP server is the one live consumer of BE_ACCOUNT_ID:
AgentsInfraStack injects it from config/accounts.json -> backend.accountId. A
missing value must be a hard startup failure rather than a silent fallback to a
literal, because an MCP server that starts and then queries the wrong account is
worse than one that never starts.

Validates: Requirements 5.1, 5.2, 5.3
"""

import importlib
import re
import sys
from pathlib import Path

import pytest

CONFIG_SOURCE = Path(__file__).resolve().parent.parent / "src" / "config.py"


def _import_config_fresh():
    """Import src.config with no cached module, so module-level code re-runs."""
    sys.modules.pop("src.config", None)
    return importlib.import_module("src.config")


class TestBeAccountIdRequired:
    def test_unset_variable_fails_at_import_naming_the_variable(self, monkeypatch):
        monkeypatch.delenv("BE_ACCOUNT_ID", raising=False)
        with pytest.raises(RuntimeError) as excinfo:
            _import_config_fresh()
        message = str(excinfo.value)
        assert "BE_ACCOUNT_ID" in message
        assert "config/accounts.json" in message

    def test_blank_variable_is_treated_as_unset(self, monkeypatch):
        monkeypatch.setenv("BE_ACCOUNT_ID", "   ")
        with pytest.raises(RuntimeError) as excinfo:
            _import_config_fresh()
        assert "BE_ACCOUNT_ID" in str(excinfo.value)

    def test_supplied_value_is_the_value_used(self, monkeypatch):
        monkeypatch.setenv("BE_ACCOUNT_ID", "111111111111")
        config = _import_config_fresh()
        assert config.BE_ACCOUNT_ID == "111111111111"
        assert config.BE_READ_ROLE_ARN == (
            "arn:aws:iam::111111111111:role/aiops-backend-domain-read"
        )

    def test_value_is_stripped(self, monkeypatch):
        monkeypatch.setenv("BE_ACCOUNT_ID", "  222222222222  ")
        config = _import_config_fresh()
        assert config.BE_ACCOUNT_ID == "222222222222"


class TestNoAccountLiteralInSource:
    def test_module_contains_no_twelve_digit_literal(self):
        source = CONFIG_SOURCE.read_text()
        assert re.search(r"\d{12}", source) is None, (
            "src/config.py must contain no account-ID literal — the account is a "
            "Replicator input supplied through BE_ACCOUNT_ID"
        )


@pytest.fixture(autouse=True)
def _restore_cached_config_module():
    """Re-importing the module is this file's whole method; leave no trace.

    The original module object must go back into sys.modules: the rest of the
    suite patches attributes by module name, and a replacement object would
    leave those patches applied to a module nobody calls.
    """
    original = sys.modules.get("src.config")
    yield
    if original is not None:
        sys.modules["src.config"] = original
    else:
        sys.modules.pop("src.config", None)
