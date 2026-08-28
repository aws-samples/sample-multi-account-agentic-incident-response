"""Bedrock Knowledge Base retrieval tool for the KB agent.

Queries the Bedrock KB Retrieve API and returns relevant passages with
source citations for grounding the agent's investigation.
"""

from __future__ import annotations

import os
from typing import Any

import boto3
from botocore.config import Config

_REGION = os.environ.get("AWS_REGION", "us-east-1")
_KB_ID = os.environ.get("KNOWLEDGE_BASE_ID", "")
_SSM_KB_PARAM = "/aiops-poc/kb/knowledge-base-id"

_boto_config = Config(
    region_name=_REGION,
    retries={"max_attempts": 2, "mode": "standard"},
)


def _resolve_kb_id() -> str:
    """Resolve the Knowledge Base ID from env or SSM."""
    if _KB_ID:
        return _KB_ID
    try:
        ssm = boto3.client("ssm", config=_boto_config)
        response = ssm.get_parameter(Name=_SSM_KB_PARAM)
        return response["Parameter"]["Value"]
    except Exception:
        return ""


def retrieve_from_kb(
    query: str,
    max_results: int = 5,
    bedrock_client: Any | None = None,
) -> dict[str, Any]:
    """Retrieve relevant passages from the Bedrock Knowledge Base.

    Args:
        query: The search query (natural language).
        max_results: Maximum number of retrieval results.
        bedrock_client: Optional pre-configured client (for testing).

    Returns:
        Dict with 'passages' (list of text+source) and 'citations' (list of
        source references for the report's kb_citations field).
    """
    kb_id = _resolve_kb_id()
    if not kb_id:
        return {
            "passages": [],
            "citations": [],
            "error": "Knowledge Base ID not configured",
        }

    client = bedrock_client or boto3.client(
        "bedrock-agent-runtime", config=_boto_config
    )

    try:
        response = client.retrieve(
            knowledgeBaseId=kb_id,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "vectorSearchConfiguration": {
                    "numberOfResults": max_results,
                }
            },
        )
    except Exception as e:
        return {
            "passages": [],
            "citations": [],
            "error": f"KB retrieval failed: {str(e)}",
        }

    passages = []
    citations = []

    for result in response.get("retrievalResults", []):
        content = result.get("content", {}).get("text", "")
        location = result.get("location", {})
        source = ""

        if location.get("type") == "S3":
            uri = location.get("s3Location", {}).get("uri", "")
            source = uri.split("/")[-1] if uri else "unknown"
        else:
            source = location.get("type", "unknown")

        score = result.get("score", 0.0)

        passages.append(
            {
                "text": content,
                "source": source,
                "score": score,
            }
        )

        if source and source not in citations:
            citations.append(source)

    return {
        "passages": passages,
        "citations": citations,
    }


# Strands tool definition
def kb_retrieve(query: str, max_results: int = 5) -> str:
    """Search the PetAdoptions architecture knowledge base for relevant context.

    Use this tool to retrieve architecture documentation, investigation
    procedures, and service topology information. Always cite the sources
    returned in your investigation report.

    Args:
        query: Natural language query describing what you need to understand.
        max_results: Number of passages to retrieve (default 5).

    Returns:
        Retrieved passages with source citations.
    """
    result = retrieve_from_kb(query, max_results)

    if result.get("error"):
        return f"KB retrieval error: {result['error']}"

    if not result["passages"]:
        return "No relevant passages found in the knowledge base."

    output_parts = []
    for i, passage in enumerate(result["passages"], 1):
        output_parts.append(
            f"[{i}] Source: {passage['source']} (relevance: {passage['score']:.2f})\n"
            f"{passage['text']}\n"
        )

    output_parts.append(
        f"\nCitations to include in report: {result['citations']}"
    )

    return "\n".join(output_parts)
