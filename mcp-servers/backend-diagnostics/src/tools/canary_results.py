"""get_canary_results — CloudWatch Synthetics canary results."""

from ..aws_client import get_client
from ..config import CANARY_NAMES


def get_canary_results(canary_name: str | None = None) -> dict:
    """Return canary results (pass/fail, duration, last run details).

    Args:
        canary_name: Optional specific canary. If None, returns all configured canaries.

    Returns:
        Dict with canary results.
    """
    synthetics = get_client("synthetics")

    canaries_to_check = [canary_name] if canary_name else CANARY_NAMES

    results = {}
    for name in canaries_to_check:
        try:
            # Get canary status
            canary_resp = synthetics.get_canary(Name=name)
            canary = canary_resp["Canary"]

            status = canary.get("Status", {})
            timeline = canary.get("Timeline", {})

            canary_info = {
                "state": status.get("State"),
                "state_reason": status.get("StateReason", ""),
                "schedule_expression": canary.get("Schedule", {}).get("Expression", ""),
            }

            if timeline.get("LastStarted"):
                canary_info["last_started"] = timeline["LastStarted"].isoformat()
            if timeline.get("LastStopped"):
                canary_info["last_stopped"] = timeline["LastStopped"].isoformat()

        except Exception as e:
            results[name] = {"error": str(e)}
            continue

        # Get last runs
        try:
            runs_resp = synthetics.get_canary_runs(Name=name, MaxResults=5)
            runs = []
            for run in runs_resp.get("CanaryRuns", []):
                run_status = run.get("Status", {})
                run_timeline = run.get("Timeline", {})
                run_info = {
                    "state": run_status.get("State"),
                    "state_reason": run_status.get("StateReason", ""),
                }
                if run_timeline.get("Started"):
                    run_info["started"] = run_timeline["Started"].isoformat()
                if run_timeline.get("Completed"):
                    run_info["completed"] = run_timeline["Completed"].isoformat()
                    if run_timeline.get("Started"):
                        duration = (
                            run_timeline["Completed"] - run_timeline["Started"]
                        ).total_seconds()
                        run_info["duration_seconds"] = duration
                runs.append(run_info)

            canary_info["recent_runs"] = runs
        except Exception as e:
            canary_info["runs_error"] = str(e)

        results[name] = canary_info

    return {"canaries": results}
