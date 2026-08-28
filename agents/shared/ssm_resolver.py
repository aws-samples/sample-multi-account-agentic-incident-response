"""SSM Parameter-based resource resolution.

Reads resource names/ARNs stored under `/aiops-poc/workload/*` so that tool
wrappers and agents never hardcode resource identifiers.
"""

from __future__ import annotations

import os
from typing import Any

import boto3
from botocore.config import Config

_REGION = os.environ.get("AWS_REGION", "us-east-1")
_SSM_PREFIX = os.environ.get("SSM_PREFIX", "/aiops-poc/workload")

_boto_config = Config(
    region_name=_REGION,
    retries={"max_attempts": 2, "mode": "standard"},
)


class SSMResolver:
    """Resolve workload resource names from SSM parameters.

    Parameters are stored by the backend overlay stack under
    `/aiops-poc/workload/<key>`. This class caches values for the lifetime
    of the instance.
    """

    def __init__(self, ssm_client: Any | None = None, prefix: str = _SSM_PREFIX) -> None:
        self._ssm = ssm_client or boto3.client("ssm", config=_boto_config)
        self._prefix = prefix
        self._cache: dict[str, str] = {}

    def get(self, key: str) -> str:
        """Return the value for *key* (relative to the prefix).

        Raises KeyError if the parameter does not exist.
        """
        if key in self._cache:
            return self._cache[key]

        path = f"{self._prefix}/{key}"
        try:
            response = self._ssm.get_parameter(Name=path)
            value = response["Parameter"]["Value"]
        except self._ssm.exceptions.ParameterNotFound:
            raise KeyError(f"SSM parameter not found: {path}")

        self._cache[key] = value
        return value

    def get_all(self) -> dict[str, str]:
        """Return all parameters under the prefix (paginated)."""
        if self._cache:
            return dict(self._cache)

        params: dict[str, str] = {}
        paginator = self._ssm.get_paginator("get_parameters_by_path")
        for page in paginator.paginate(Path=self._prefix, Recursive=True):
            for p in page.get("Parameters", []):
                # Strip prefix to get the relative key
                relative = p["Name"][len(self._prefix) :].lstrip("/")
                params[relative] = p["Value"]

        self._cache.update(params)
        return params

    def refresh(self) -> None:
        """Clear the cache so next access re-reads from SSM."""
        self._cache.clear()
