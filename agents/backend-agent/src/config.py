"""Agent configuration constants."""

from __future__ import annotations

import os

# Server settings
A2A_PORT = int(os.environ.get("A2A_PORT", "9000"))
A2A_HOST = os.environ.get("A2A_HOST", "0.0.0.0")  # nosec B104  # AgentCore Runtime ingress requires the container to listen on 0.0.0.0; the port is not internet-facing and callers are authenticated with SigV4 at the data plane

# Agent identity
AGENT_NAME = "backend-devops-agent"
AGENT_DESCRIPTION = (
    "Runbook-consultation agent for the PetAdoptions backend domain. "
    "Consults the documented runbook/playbook catalog (Agent Skills) for a "
    "symptom and returns documented likely root causes, the verification "
    "steps the owning team should run, and documented remediation guidance. "
    "No live telemetry — findings are documented knowledge, not observed fact."
)

# Timeouts
INVESTIGATION_TIMEOUT_SECONDS = int(os.environ.get("INVESTIGATION_TIMEOUT", "600"))  # 10 minutes

# AWS
# No BE_ACCOUNT_ID here: this agent is knowledge-only since the descope, so
# AgentsInfraStack injects no backend account into its runtime (see
# agents-infra-stack.ts and the knowledge-only note in src/tools.py). The
# literal that used to sit here was a dead value, and dead values are how a
# stale account ID survives a Replicator handover (Requirements 5.1, 5.2).
BE_ROLE_NAME = os.environ.get("BE_ROLE_NAME", "aiops-backend-domain-read")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# No REPORT_BUCKET here either, for the same reason. It was read by nothing —
# archival goes through agents/shared/report.py, which resolves the bucket
# itself — and its default `aiops-poc-reports` names a bucket that exists in no
# deployment: AgentsInfraStack creates `aiops-poc-reports-<ops-account>`. A dead
# value that is also wrong is the worst of both.
