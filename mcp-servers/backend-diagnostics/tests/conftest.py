"""Shared test fixtures for the diagnostics MCP server tests."""

import os

import pytest
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

# src.config requires BE_ACCOUNT_ID at import time (Requirement 5.3), and the
# stack injects it in a deploy. Supply the canonical BE placeholder here so the
# suite exercises the same code path a runtime does — never a real account.
os.environ.setdefault("BE_ACCOUNT_ID", "111111111111")


@pytest.fixture
def mock_get_client():
    """Patch get_client to return a mock boto3 client."""
    with patch("src.aws_client.get_be_session") as mock_session:
        mock_session.return_value = MagicMock()
        yield mock_session


@pytest.fixture
def utc_now():
    """Return a fixed UTC datetime for deterministic tests."""
    return datetime(2025, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
