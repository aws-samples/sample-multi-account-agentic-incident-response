"""Region-contract tests for the webhook bridge Lambda.

AWS_REGION is set by the Lambda runtime itself and is a reserved key that cannot
appear in a CDK environment block, so the handler reads it ambiently — but with
no literal fallback, because a hardcoded region is wrong for the next deployment.

Validates: Requirements 5.1, 5.2, 5.4
"""

import importlib
import re
import sys
from pathlib import Path

import pytest

HANDLER_SOURCE = Path(__file__).resolve().parent.parent / "handler.py"


def _import_handler_fresh():
    sys.modules.pop("handler", None)
    return importlib.import_module("handler")


class TestRegionIsAmbient:
    def test_region_comes_from_the_environment(self, monkeypatch):
        monkeypatch.setenv("AWS_REGION", "us-east-1")
        handler_module = _import_handler_fresh()
        assert handler_module.REGION == "us-east-1"

    def test_unset_region_leaves_resolution_to_boto3(self, monkeypatch):
        monkeypatch.delenv("AWS_REGION", raising=False)
        handler_module = _import_handler_fresh()
        assert handler_module.REGION == ""


class TestNoLiteralsInSource:
    def test_no_region_literal(self):
        source = HANDLER_SOURCE.read_text()
        assert not re.search(r"[a-z]{2}-[a-z]+-\d", source), (
            "handler.py must contain no region literal — the region is ambient"
        )

    def test_no_twelve_digit_literal(self):
        source = HANDLER_SOURCE.read_text()
        assert re.search(r"\d{12}", source) is None, (
            "handler.py must contain no account-ID literal"
        )


@pytest.fixture(autouse=True)
def _restore_cached_handler_module():
    """Re-importing the module is this file's whole method; leave no trace.

    The original module object must go back into sys.modules: the rest of the
    suite patches attributes by the name "handler", and a replacement object
    would leave those patches applied to a module nobody calls.
    """
    original = sys.modules.get("handler")
    yield
    if original is not None:
        sys.modules["handler"] = original
    else:
        sys.modules.pop("handler", None)
