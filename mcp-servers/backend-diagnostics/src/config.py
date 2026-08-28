"""Configuration constants for the backend diagnostics MCP server."""

import os


def _require_env(name: str) -> str:
    """Return the environment variable *name* or fail at startup.

    A missing required variable is a hard failure, never a fallback: an MCP
    server that starts and then queries the wrong account is worse than one
    that never starts (Requirement 5.3).
    """
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(
            f"{name} is not set. AgentsInfraStack injects it from "
            f"config/accounts.json; see config/accounts.json.template."
        )
    return value


# AWS region for all API calls — resolved from the runtime environment
# (AgentCore Runtime sets AWS_REGION; AgentsInfraStack also injects both
# region variables into this runtime), falling back to us-east-1.
REGION = (
    os.environ.get("AWS_REGION")
    or os.environ.get("AWS_DEFAULT_REGION")
    or "us-east-1"
)

# Backend account ID (for STS assume-role) — required, with no literal
# fallback. AgentsInfraStack injects BE_ACCOUNT_ID from
# config/accounts.json → backend.accountId.
BE_ACCOUNT_ID = _require_env("BE_ACCOUNT_ID")

# IAM role to assume in the BE account (read-only)
BE_READ_ROLE_ARN = f"arn:aws:iam::{BE_ACCOUNT_ID}:role/aiops-backend-domain-read"

# ECS cluster and services — fixed names in the pinned upstream
# PetAdoptions sample (verified against the live deployment).
ECS_CLUSTER = "PetsiteECS-cluster"
ECS_SERVICES = [
    "payforadoption-go",
    "petsearch-java",
    "petlistadoption-py",
    "petfood-rs",
]

# NO CONSTANTS for the adoptions DynamoDB table, the status-update SQS queue,
# the Aurora cluster identifier or the status-updater Lambda.
#
# The upstream creates all four without an explicit physical name, so
# CloudFormation generates one per deployment and no literal can be correct in
# a fresh account. They are resolved at runtime instead — from the upstream's
# own /petstore/* SSM contract, or from a resource lookup derived from it — in
# src/resource_resolver.py, which also documents the resolution order and why
# there is no literal fallback. Do not re-add a "corrected" constant here: a
# name copied from one deployment is wrong in every other one.

# CloudWatch canary names — the upstream names both canaries explicitly
# (constructs/canary.ts CanaryNames), so these are fixed by the pinned ref
# rather than generated, and are verified against the live deployment.
CANARY_NAMES = [
    "petsite-canary",
    "housekeeping-canary",
]

# CloudWatch alarm prefix for filtering
ALARM_PREFIX = "aiops-poc"
