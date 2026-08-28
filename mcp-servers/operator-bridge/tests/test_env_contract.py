"""Environment-contract tests for the operator bridge.

The operator's mcp.json supplies AWS_REGION from config/accounts.json ->
ops.region. There is no literal fallback: a bridge pointed at the wrong region
silently reads the wrong estate, so an unset region is a startup failure.

Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.6
"""

from __future__ import annotations

import importlib
import re
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

SERVER_SOURCE = Path(__file__).resolve().parent.parent / "server.py"


def _import_server_fresh():
    sys.modules.pop("server", None)
    return importlib.import_module("server")


class TestRegionRequired:
    def test_unset_region_fails_at_import_naming_the_variable(self, monkeypatch):
        monkeypatch.delenv("AWS_REGION", raising=False)
        monkeypatch.delenv("AWS_DEFAULT_REGION", raising=False)
        with pytest.raises(RuntimeError) as excinfo:
            _import_server_fresh()
        message = str(excinfo.value)
        assert "AWS_REGION" in message
        assert "ops.region" in message

    def test_blank_region_is_treated_as_unset(self, monkeypatch):
        monkeypatch.setenv("AWS_REGION", "   ")
        monkeypatch.delenv("AWS_DEFAULT_REGION", raising=False)
        with pytest.raises(RuntimeError) as excinfo:
            _import_server_fresh()
        assert "AWS_REGION" in str(excinfo.value)

    def test_supplied_region_is_the_value_used(self, monkeypatch):
        monkeypatch.setenv("AWS_REGION", "us-east-1")
        server = _import_server_fresh()
        assert server.REGION == "us-east-1"

    def test_default_region_variable_is_accepted(self, monkeypatch):
        monkeypatch.delenv("AWS_REGION", raising=False)
        monkeypatch.setenv("AWS_DEFAULT_REGION", "us-west-2")
        server = _import_server_fresh()
        assert server.REGION == "us-west-2"


class TestNoIdentifyingLiterals:
    def test_module_contains_no_twelve_digit_literal(self):
        source = SERVER_SOURCE.read_text()
        assert re.search(r"\d{12}", source) is None, (
            "server.py must name accounts by role, never by identifier"
        )

    def test_module_declares_no_region_fallback(self):
        source = SERVER_SOURCE.read_text()
        assert 'os.environ.get("AWS_REGION", "' not in source, (
            "the region must have no literal default"
        )


@pytest.fixture(autouse=True)
def _restore_cached_server_module():
    """Re-importing the module is this file's whole method; leave no trace.

    The original module object must go back into sys.modules: the rest of the
    suite patches attributes by the name "server", and a replacement object
    would leave those patches applied to a module nobody calls.
    """
    original = sys.modules.get("server")
    yield
    if original is not None:
        sys.modules["server"] = original
    else:
        sys.modules.pop("server", None)


class TestReportsBucketHasNoLiteralDefault:
    """The reports bucket is derived, never guessed.

    `agents/infra` creates `aiops-poc-reports-<ops-account>`. The old unsuffixed
    default named a bucket that exists in no deployment, and because S3 bucket
    names are a single global namespace, an unsuffixed guess either fails or
    reads and writes incident reports in a bucket somebody else owns.
    """

    def test_environment_variable_wins(self, monkeypatch):
        monkeypatch.setenv("AWS_REGION", "us-east-1")
        monkeypatch.setenv("REPORTS_BUCKET", "aiops-poc-reports-333333333333")
        server = _import_server_fresh()
        assert server.reports_bucket() == "aiops-poc-reports-333333333333"

    def test_missing_variable_derives_the_name_from_the_caller_account(
        self, monkeypatch
    ):
        monkeypatch.setenv("AWS_REGION", "us-east-1")
        monkeypatch.delenv("REPORTS_BUCKET", raising=False)
        server = _import_server_fresh()

        sts = MagicMock()
        sts.get_caller_identity.return_value = {"Account": "333333333333"}
        session = MagicMock()
        session.client.return_value = sts
        with patch.object(server, "_get_boto_session", return_value=session):
            assert server.reports_bucket() == "aiops-poc-reports-333333333333"
            # Cached: a second call asks nobody.
            server.reports_bucket()
        assert sts.get_caller_identity.call_count == 1

    def test_unresolvable_account_fails_naming_the_variable_and_the_shape(
        self, monkeypatch
    ):
        monkeypatch.setenv("AWS_REGION", "us-east-1")
        monkeypatch.delenv("REPORTS_BUCKET", raising=False)
        server = _import_server_fresh()

        with patch.object(
            server, "_get_boto_session", side_effect=RuntimeError("no credentials")
        ):
            with pytest.raises(RuntimeError) as excinfo:
                server.reports_bucket()

        message = str(excinfo.value)
        assert "REPORTS_BUCKET" in message
        assert "aiops-poc-reports-<ops-account-id>" in message
        assert "docs/operator-ide.md" in message

    def test_module_declares_no_bucket_fallback(self):
        """`os.environ.get("REPORTS_BUCKET", "")` is fine; a name is not."""
        source = SERVER_SOURCE.read_text()
        assert (
            re.search(r'environ\.get\(\s*"REPORTS_BUCKET"\s*,\s*"[^"]+"', source)
            is None
        ), "the reports bucket must have no literal default"
