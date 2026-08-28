"""Agent card definition for backend-kb-agent.

Satisfies DevOps Agent remote-agent required fields:
- name, description, supportedInterfaces, capabilities, skills
(Requirement 8.3)
"""

from __future__ import annotations

AGENT_CARD = {
    "name": "backend-kb-agent",
    "description": (
        "KB-grounded documentation-consultation agent for the PetAdoptions "
        "platform. Retrieves architecture documentation from Bedrock Knowledge "
        "Base to ground findings in documented facts — no live telemetry. "
        "Returns documented likely root causes for backend service symptoms "
        "(checkout latency, payment failures, search degradation, status "
        "update delays) with citations, plus the checks the owning team "
        "should run, and escalates a summary to the owning team via SNS."
    ),
    "version": "0.1.0",
    "supportedInterfaces": ["a2a"],
    "capabilities": {
        "investigation": True,
        "remediation": False,
        "knowledgeBase": True,
        "streaming": False,
    },
    "skills": [
        {
            "name": "kb-grounded-investigation",
            "description": (
                "Consult Knowledge Base documentation for backend service "
                "symptoms (ECS, Aurora, DynamoDB, SQS, Lambda). Returns "
                "documented findings with KB citations — no live telemetry."
            ),
        },
        {
            "name": "checkout-latency-analysis",
            "description": (
                "Investigate slow adoption checkout (payforadoption → Aurora path) "
                "grounded in KB architecture documentation."
            ),
        },
        {
            "name": "search-availability-analysis",
            "description": (
                "Investigate search failures or degradation (petsearch → DynamoDB "
                "path) grounded in KB architecture documentation."
            ),
        },
        {
            "name": "status-lag-analysis",
            "description": (
                "Investigate adoption status update delays (SQS → petstatusupdater "
                "→ DynamoDB async path) grounded in KB architecture documentation."
            ),
        },
        {
            "name": "payments-failure-analysis",
            "description": (
                "Investigate adoption/payment failures (payforadoption errors or "
                "crashes) grounded in KB architecture documentation."
            ),
        },
    ],
    "constraints": {
        "investigationOnly": True,
        "readOnly": True,
        "timeoutSeconds": 600,
    },
}
