"""get_recent_alarms — Recent CloudWatch alarm state changes in BE."""

from datetime import datetime, timedelta, timezone

from ..aws_client import get_client
from ..config import ALARM_PREFIX


def get_recent_alarms(minutes: int = 60) -> dict:
    """Return recent CloudWatch alarm state changes filtered to aiops-poc.

    Args:
        minutes: Lookback window in minutes (default 60).

    Returns:
        Dict with recent alarm state changes.
    """
    cw = get_client("cloudwatch")

    # Get alarms with the aiops-poc prefix
    paginator = cw.get_paginator("describe_alarms")
    alarms = []
    for page in paginator.paginate(AlarmNamePrefix=ALARM_PREFIX):
        for alarm in page.get("MetricAlarms", []):
            alarms.append(alarm)
        for alarm in page.get("CompositeAlarms", []):
            alarms.append(alarm)

    # Get alarm history for the lookback window
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=minutes)

    results = []
    for alarm in alarms:
        alarm_name = alarm["AlarmName"]
        current_state = {
            "alarm_name": alarm_name,
            "current_state": alarm.get("StateValue"),
            "state_reason": alarm.get("StateReason", ""),
            "state_updated": (
                alarm["StateUpdatedTimestamp"].isoformat()
                if alarm.get("StateUpdatedTimestamp")
                else None
            ),
        }

        # Get state change history
        try:
            history_resp = cw.describe_alarm_history(
                AlarmName=alarm_name,
                HistoryItemType="StateUpdate",
                StartDate=start_time,
                EndDate=end_time,
                MaxRecords=10,
            )
            state_changes = []
            for item in history_resp.get("AlarmHistoryItems", []):
                state_changes.append(
                    {
                        "timestamp": item["Timestamp"].isoformat(),
                        "summary": item.get("HistorySummary", ""),
                    }
                )
            current_state["recent_state_changes"] = state_changes
        except Exception:
            current_state["recent_state_changes"] = []

        results.append(current_state)

    return {
        "lookback_minutes": minutes,
        "alarm_prefix": ALARM_PREFIX,
        "alarms": results,
    }
