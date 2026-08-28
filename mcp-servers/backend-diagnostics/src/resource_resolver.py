"""Runtime resolution of the PetAdoptions resources CloudFormation names.

Four of the resources this MCP server inspects have **no fixed name**: the
upstream PetAdoptions sample creates them without an explicit physical name, so
CloudFormation generates one and appends a random suffix. Every one of them is
therefore different in every account the sample is deployed into, and no literal
constant can be correct in a fresh clone:

    adoptions DynamoDB table   Dev<Stack>-DynamoDbddbPetadoption<hash>-<random>
    status-update SQS queue    Dev<Stack>-QueueResourcessqspetadoption<hash>-<random>
    Aurora cluster identifier  dev<stack>-auroradatabase<hash>-<random>
    status-updater Lambda      whatever the upstream names its queue consumer

This module resolves each of them at runtime. Resolution order, per resource:

    1. an explicit value supplied by the caller (the tools' optional
       ``table_name`` / ``queue_name`` / ``cluster_id`` / ``function_name``
       arguments) — always wins, and is never second-guessed;
    2. the upstream's own service-discovery contract in SSM Parameter Store
       under ``/petstore/*`` in the backend account, or a resource lookup
       derived from it;
    3. failure, with a message naming the parameter, the account and region it
       was read from, and the argument that bypasses the lookup.

There is deliberately **no fallback to a literal**. A stale name that looks
plausible produces a confident wrong answer — an empty metric series read as
"no traffic", a `ResourceNotFound` read as "the table is gone" — which is worse
during an incident than a resolution error that says exactly what is missing.

Credentials and region come from the same place as every other AWS call in this
server: :func:`src.aws_client.get_client` assumes the backend read role in
``REGION``, both of which `AgentsInfraStack` injects from
``config/accounts.json``. This module introduces no second environment contract.

Resolved values are cached for the lifetime of the process. A deployment's
physical names do not change while it lives, so re-reading SSM on every tool
call would add latency and API calls for a value that cannot have moved.
Failures are **not** cached: a backend deploy that finishes after this server
starts should be picked up by the next call.
"""

from __future__ import annotations

import threading
from typing import Callable

from .aws_client import get_client
from .config import BE_ACCOUNT_ID, REGION

# ─── The upstream SSM contract (see docs/parameters.md) ──────────────────────

#: Physical name of the adoptions DynamoDB table.
ADOPTIONS_TABLE_PARAMETER = "/petstore/dynamodbtablename"

#: Full queue URL of the pet status-update SQS queue. The queue's name is the
#: URL's last path segment.
STATUS_UPDATE_QUEUE_PARAMETER = "/petstore/queueurl"

#: Aurora writer endpoint. The upstream publishes no parameter for the cluster
#: *identifier*, but a writer endpoint's first DNS label is the identifier, so
#: this parameter carries it (see :func:`cluster_id_from_value`).
RDS_WRITER_ENDPOINT_PARAMETER = "/petstore/rds-writer-endpoint"


class ResourceResolutionError(RuntimeError):
    """A deployment-specific resource name could not be resolved.

    Raised instead of returning a guess. The message is written for whoever
    reads the tool's output — it names the parameter, the account and region,
    and the argument that skips the lookup.
    """


# ─── Cache ───────────────────────────────────────────────────────────────────
# One entry per logical resource, for the lifetime of the process. The lock
# makes "resolve once" an invariant rather than a likelihood: the MCP server is
# stateless-HTTP and may serve concurrent tool calls on separate threads.

_CACHE: dict[str, str] = {}

# Reentrant, because one resolution legitimately nests inside another: the
# status-updater function is found through the queue URL, so resolving it enters
# the cache twice on the same thread. A plain Lock deadlocks there.
_LOCK = threading.RLock()


def clear_cache() -> None:
    """Drop every cached value. For tests, and for a manual re-read."""
    with _LOCK:
        _CACHE.clear()


def _cached(key: str, produce: Callable[[], str]) -> str:
    """Return the cached value for *key*, else produce, store and return it.

    Double-checked so a concurrent caller cannot cause a second lookup, and so
    a lookup that raises leaves no entry behind.
    """
    value = _CACHE.get(key)
    if value is not None:
        return value
    with _LOCK:
        value = _CACHE.get(key)
        if value is not None:
            return value
        value = produce()
        _CACHE[key] = value
        return value


# ─── Failure messages ────────────────────────────────────────────────────────


def _failure(what: str, parameter: str, bypass: str, cause: str) -> ResourceResolutionError:
    """Build the one error shape this module raises.

    Names all three things the reader needs to act: the parameter that could
    not be read, where it was looked for, and the argument that skips the
    lookup entirely.
    """
    return ResourceResolutionError(
        f"cannot resolve the {what}: SSM parameter {parameter} could not be read "
        f"from account {BE_ACCOUNT_ID} in region {REGION} ({cause}). "
        f"The upstream PetAdoptions deploy publishes it, so a missing parameter "
        f"usually means the backend deployment has not finished in that account "
        f"and region — check with "
        f"`aws ssm get-parameter --name {parameter}`. "
        f"To bypass the lookup, pass {bypass}."
    )


def _read_parameter(what: str, parameter: str, bypass: str) -> str:
    """Read one SSM parameter from the backend account, or raise."""
    ssm = get_client("ssm")
    try:
        response = ssm.get_parameter(Name=parameter)
    except Exception as exc:  # ParameterNotFound, AccessDenied, network, …
        raise _failure(
            what, parameter, bypass, f"{type(exc).__name__}: {exc}"
        ) from exc

    value = str((response.get("Parameter") or {}).get("Value") or "").strip()
    if not value:
        raise _failure(what, parameter, bypass, "the parameter exists but is empty")
    return value


# ─── DynamoDB: the adoptions table ───────────────────────────────────────────


def resolve_adoptions_table(table_name: str | None = None) -> str:
    """Return the adoptions DynamoDB table name.

    Args:
        table_name: An explicit table name from the caller. Wins outright.
    """
    if table_name and table_name.strip():
        return table_name.strip()

    return _cached(
        "adoptions_table",
        lambda: _read_parameter(
            "adoptions DynamoDB table name",
            ADOPTIONS_TABLE_PARAMETER,
            "tool_get_dynamodb_health(table_name=...)",
        ),
    )


# ─── SQS: the status-update queue ────────────────────────────────────────────


def _queue_url_for_name(name: str) -> str:
    return f"https://sqs.{REGION}.amazonaws.com/{BE_ACCOUNT_ID}/{name}"


def resolve_status_update_queue(queue_name: str | None = None) -> tuple[str, str]:
    """Return ``(queue_url, queue_name)`` for the pet status-update queue.

    Args:
        queue_name: An explicit queue name **or** full queue URL from the
            caller. Wins outright. A queue URL always contains ``/`` and a bare
            queue name never can, so the last path segment is an unambiguous way
            to accept either form.
    """
    if queue_name and queue_name.strip():
        given = queue_name.strip().rstrip("/")
        name = given.rsplit("/", 1)[-1]
        return (given if "/" in given else _queue_url_for_name(name)), name

    url = _cached(
        "status_update_queue_url",
        lambda: _read_parameter(
            "pet status-update SQS queue URL",
            STATUS_UPDATE_QUEUE_PARAMETER,
            "tool_get_queue_stats(queue_name=...)",
        ),
    )
    return url, url.rstrip("/").rsplit("/", 1)[-1]


# ─── RDS: the Aurora cluster identifier ──────────────────────────────────────


def cluster_id_from_value(value: str) -> str:
    """Return the DB cluster identifier carried by *value*.

    Accepts the identifier itself, or an Aurora writer/reader endpoint
    hostname. A ``DBClusterIdentifier`` may only contain letters, digits and
    hyphens, so a dotted value is unambiguously a hostname.

    Aurora writer and reader endpoints are
    ``<cluster-id>.cluster-<dns-id>.<region>.rds.amazonaws.com`` and
    ``<cluster-id>.cluster-ro-<dns-id>.<region>.rds.amazonaws.com``: the first
    label *is* the cluster identifier, so reading it out is a fact about the
    endpoint, not a guess. No other endpoint form carries it — a custom
    endpoint's first label is the custom endpoint's own name, and an instance
    endpoint's is the instance identifier — so those are rejected rather than
    guessed at.

    Raises:
        ResourceResolutionError: if *value* is a hostname the cluster
            identifier cannot be read out of.
    """
    value = value.strip()
    if "." not in value:
        return value

    labels = value.rstrip(".").split(".")
    second = labels[1] if len(labels) > 1 else ""
    if second.startswith("cluster-") and not second.startswith("cluster-custom-"):
        return labels[0]

    raise ResourceResolutionError(
        f"cannot derive a DB cluster identifier from {value!r}: only an Aurora "
        "writer or reader endpoint (<cluster-id>.cluster-<dns-id>... or "
        "<cluster-id>.cluster-ro-<dns-id>...) carries the identifier. Pass the "
        "DBClusterIdentifier itself instead."
    )


def resolve_rds_cluster_id(cluster_id: str | None = None) -> str:
    """Return the Aurora cluster identifier for the PetAdoptions database.

    Args:
        cluster_id: An explicit cluster identifier **or** a writer/reader
            endpoint hostname from the caller. Wins outright.
    """
    if cluster_id and cluster_id.strip():
        return cluster_id_from_value(cluster_id)

    return _cached(
        "rds_cluster_id",
        lambda: cluster_id_from_value(
            _read_parameter(
                "Aurora cluster identifier",
                RDS_WRITER_ENDPOINT_PARAMETER,
                "tool_get_db_health(cluster_id=...)",
            )
        ),
    )


# ─── Lambda: the status-updater function ─────────────────────────────────────


def _status_updater_function_name() -> str:
    """Resolve the status-update queue's consumer function by its mapping.

    No SSM parameter publishes the function's name, and the upstream's own name
    for it is not something to rely on — what the diagnostics actually mean by
    "the status updater" is *the function consuming the status-update queue*.
    That is a fact the account can be asked for: turn the queue URL into a
    queue ARN and read the function off its event source mapping. The chaos
    scripts (`chaos/scripts/inject.sh`, `status-consumer-off`) resolve it the
    same way, so the two cannot disagree about which function they mean.
    """
    bypass = "tool_get_lambda_stats(function_name=...)"
    queue_url, _ = resolve_status_update_queue()

    sqs = get_client("sqs")
    try:
        attributes = sqs.get_queue_attributes(
            QueueUrl=queue_url, AttributeNames=["QueueArn"]
        )
        queue_arn = str((attributes.get("Attributes") or {}).get("QueueArn") or "")
    except Exception as exc:
        raise _failure(
            "status-updater Lambda function name",
            STATUS_UPDATE_QUEUE_PARAMETER,
            bypass,
            f"the queue it names could not be read: {type(exc).__name__}: {exc}",
        ) from exc

    if not queue_arn:
        raise _failure(
            "status-updater Lambda function name",
            STATUS_UPDATE_QUEUE_PARAMETER,
            bypass,
            "the queue it names reported no QueueArn",
        )

    lambda_client = get_client("lambda")
    try:
        mappings = lambda_client.list_event_source_mappings(EventSourceArn=queue_arn)
    except Exception as exc:
        raise _failure(
            "status-updater Lambda function name",
            STATUS_UPDATE_QUEUE_PARAMETER,
            bypass,
            f"its event source mappings could not be listed: "
            f"{type(exc).__name__}: {exc}",
        ) from exc

    for mapping in mappings.get("EventSourceMappings") or []:
        function_arn = str(mapping.get("FunctionArn") or "")
        if function_arn:
            return function_arn.rsplit(":", 1)[-1]

    raise _failure(
        "status-updater Lambda function name",
        STATUS_UPDATE_QUEUE_PARAMETER,
        bypass,
        f"no Lambda event source mapping consumes {queue_arn}",
    )


def resolve_status_updater_function_name(function_name: str | None = None) -> str:
    """Return the name of the Lambda consuming the status-update queue.

    Args:
        function_name: An explicit function name from the caller. Wins
            outright.
    """
    if function_name and function_name.strip():
        return function_name.strip()

    return _cached("status_updater_function", _status_updater_function_name)
