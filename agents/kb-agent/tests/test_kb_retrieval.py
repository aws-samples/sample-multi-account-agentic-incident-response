"""Unit tests for the KB retrieval tool with mocked Bedrock client."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from kb_agent.kb_retrieval_tool import kb_retrieve, retrieve_from_kb


class TestRetrieveFromKB:
    """Test the retrieve_from_kb function with mocked Bedrock client."""

    def _mock_retrieve_response(self, results: list[dict]) -> dict:
        """Build a mock Bedrock retrieve response."""
        return {"retrievalResults": results}

    def test_returns_passages_and_citations(self) -> None:
        """Successful retrieval returns passages with citations."""
        mock_client = MagicMock()
        mock_client.retrieve.return_value = self._mock_retrieve_response([
            {
                "content": {"text": "The checkout path is petsite → payforadoption → Aurora"},
                "location": {
                    "type": "S3",
                    "s3Location": {"uri": "s3://bucket/petadoptions-architecture.md"},
                },
                "score": 0.92,
            },
            {
                "content": {"text": "Aurora blocking sessions cause latency"},
                "location": {
                    "type": "S3",
                    "s3Location": {"uri": "s3://bucket/checkout-latency-scenario.md"},
                },
                "score": 0.85,
            },
        ])

        with patch("kb_agent.kb_retrieval_tool._resolve_kb_id", return_value="kb-test-123"):
            result = retrieve_from_kb("checkout latency", bedrock_client=mock_client)

        assert len(result["passages"]) == 2
        assert result["passages"][0]["source"] == "petadoptions-architecture.md"
        assert result["passages"][0]["score"] == 0.92
        assert "petadoptions-architecture.md" in result["citations"]
        assert "checkout-latency-scenario.md" in result["citations"]
        assert "error" not in result

    def test_empty_results(self) -> None:
        """Empty retrieval results return empty lists."""
        mock_client = MagicMock()
        mock_client.retrieve.return_value = self._mock_retrieve_response([])

        with patch("kb_agent.kb_retrieval_tool._resolve_kb_id", return_value="kb-test-123"):
            result = retrieve_from_kb("nonexistent topic", bedrock_client=mock_client)

        assert result["passages"] == []
        assert result["citations"] == []

    def test_no_kb_id_returns_error(self) -> None:
        """Missing KB ID returns an error."""
        with patch("kb_agent.kb_retrieval_tool._resolve_kb_id", return_value=""):
            result = retrieve_from_kb("any query")

        assert "error" in result
        assert "not configured" in result["error"]

    def test_client_error_returns_error(self) -> None:
        """Bedrock API errors are handled gracefully."""
        mock_client = MagicMock()
        mock_client.retrieve.side_effect = Exception("AccessDenied")

        with patch("kb_agent.kb_retrieval_tool._resolve_kb_id", return_value="kb-test-123"):
            result = retrieve_from_kb("test", bedrock_client=mock_client)

        assert "error" in result
        assert "AccessDenied" in result["error"]

    def test_deduplicates_citations(self) -> None:
        """Same source referenced multiple times appears once in citations."""
        mock_client = MagicMock()
        mock_client.retrieve.return_value = self._mock_retrieve_response([
            {
                "content": {"text": "passage 1"},
                "location": {
                    "type": "S3",
                    "s3Location": {"uri": "s3://bucket/architecture.md"},
                },
                "score": 0.9,
            },
            {
                "content": {"text": "passage 2"},
                "location": {
                    "type": "S3",
                    "s3Location": {"uri": "s3://bucket/architecture.md"},
                },
                "score": 0.8,
            },
        ])

        with patch("kb_agent.kb_retrieval_tool._resolve_kb_id", return_value="kb-test-123"):
            result = retrieve_from_kb("test", bedrock_client=mock_client)

        assert len(result["passages"]) == 2
        assert result["citations"] == ["architecture.md"]


class TestKbRetrieveToolFunction:
    """Test the Strands tool wrapper function."""

    def test_formats_output_with_citations(self) -> None:
        """The tool function returns formatted text with citations."""
        mock_client = MagicMock()
        mock_client.retrieve.return_value = {
            "retrievalResults": [
                {
                    "content": {"text": "Search uses DynamoDB, not Aurora."},
                    "location": {
                        "type": "S3",
                        "s3Location": {"uri": "s3://bucket/search-failure-scenario.md"},
                    },
                    "score": 0.88,
                },
            ]
        }

        with patch("kb_agent.kb_retrieval_tool._resolve_kb_id", return_value="kb-123"):
            with patch("kb_agent.kb_retrieval_tool.boto3") as mock_boto:
                mock_boto.client.return_value = mock_client
                result = kb_retrieve("search issues")

        assert "search-failure-scenario.md" in result
        assert "Citations to include" in result

    def test_handles_no_results(self) -> None:
        """Tool function handles empty results gracefully."""
        with patch("kb_agent.kb_retrieval_tool.retrieve_from_kb") as mock_retrieve:
            mock_retrieve.return_value = {"passages": [], "citations": []}
            result = kb_retrieve("unknown topic")

        assert "No relevant passages" in result

    def test_handles_error(self) -> None:
        """Tool function surfaces errors clearly."""
        with patch("kb_agent.kb_retrieval_tool.retrieve_from_kb") as mock_retrieve:
            mock_retrieve.return_value = {
                "passages": [],
                "citations": [],
                "error": "Connection timeout",
            }
            result = kb_retrieve("any query")

        assert "error" in result.lower()
        assert "Connection timeout" in result
