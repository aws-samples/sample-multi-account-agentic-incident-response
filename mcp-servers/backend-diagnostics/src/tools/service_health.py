"""get_service_health — ECS service status for PetAdoptions services."""

from ..aws_client import get_client
from ..config import ECS_CLUSTER, ECS_SERVICES


def get_service_health(service_name: str | None = None) -> dict:
    """Return ECS service status (running tasks, desired, recent events).

    Args:
        service_name: Optional specific service name. If None, returns all services.

    Returns:
        Dict with service health details for the requested service(s).
    """
    ecs = get_client("ecs")
    services_to_check = [service_name] if service_name else ECS_SERVICES

    response = ecs.describe_services(
        cluster=ECS_CLUSTER,
        services=services_to_check,
    )

    results = {}
    for svc in response.get("services", []):
        name = svc["serviceName"]
        results[name] = {
            "status": svc.get("status"),
            "desired_count": svc.get("desiredCount", 0),
            "running_count": svc.get("runningCount", 0),
            "pending_count": svc.get("pendingCount", 0),
            "deployments": len(svc.get("deployments", [])),
            "events": [
                {"created_at": e["createdAt"].isoformat(), "message": e["message"]}
                for e in svc.get("events", [])[:5]
            ],
        }

    failures = response.get("failures", [])
    if failures:
        results["_failures"] = [
            {"arn": f.get("arn"), "reason": f.get("reason")} for f in failures
        ]

    return {"cluster": ECS_CLUSTER, "services": results}
