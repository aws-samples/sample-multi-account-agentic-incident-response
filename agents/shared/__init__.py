"""agents.shared — shared utilities for fallback agents and MCP servers.

Provides:
- aws_tools: BE-scoped boto3 read-only tool wrappers
- ssm_resolver: SSM parameter-based resource resolution
- report: structured investigation report schema + S3 archival
- instrumentation: tool-call / token / duration tracking
- skill_loader: loads skills honoring SKILLS_ENABLED / SKILLS_FILTER
"""
