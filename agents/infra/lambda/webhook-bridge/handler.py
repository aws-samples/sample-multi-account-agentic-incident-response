"""
Webhook bridge Lambda — triggered by cross-account SNS messages from both
incidents topics (BE + FE). Normalizes the SNS/CloudWatch alarm payload into
a clean business symptom, signs the request with HMAC-SHA256, and POSTs to a
DevOps Agent generic webhook URL.

Dual-path routing: alarms whose name starts with aiops-poc-be-infra- are
delivered to the PLATFORM space webhook (infra-owning space with live BE
telemetry); everything else (FE golden signals, be-slo-* business SLOs) goes
to the customer-facing app-team space webhook. If the platform secret is not
yet registered, the handler falls back to the app-team secret so nothing
breaks.

If the Secrets Manager secret does not exist or is unset, the handler sends
the message to a DLQ with a clear error message rather than silently failing.

NOTE: In an enterprise deployment, the webhook target would be ServiceNow's
inbound webhook API (same payload format, different URL in the secret).
"""

import base64
import hashlib
import hmac
import json
import logging
import os
import urllib.request
import urllib.error
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SECRET_NAME = os.environ.get("SECRET_NAME", "aiops-poc/webhook-credentials")
# Platform (infra-owning) space webhook credentials. Raw infra alarms
# (aiops-poc-be-infra-*) route here so the platform DevOps Agent space runs
# its own live RCA, keeping the customer-facing app-team space free of infra
# pages. Falls back to the app-team secret if this is not yet registered.
PLATFORM_SECRET_NAME = os.environ.get(
    "PLATFORM_SECRET_NAME", "aiops-poc/platform-webhook-credentials"
)
# Alarm-name prefix that routes to the platform space.
BE_INFRA_PREFIX = "aiops-poc-be-infra-"
DLQ_URL = os.environ.get("DLQ_URL", "")
# Region: read ambiently with no literal fallback (Requirement 5.4). AWS_REGION
# is set by the Lambda runtime itself and is a reserved key that cannot appear
# in a CDK environment block, so it is not a _require_env variable — there
# could be no populator for it. Empty means "let boto3 resolve it", which is
# only reachable outside Lambda.
REGION = os.environ.get("AWS_REGION", "")


def get_webhook_credentials(secret_name=SECRET_NAME):
    """Retrieve webhook URL and HMAC secret from Secrets Manager.

    Args:
        secret_name: name of the Secrets Manager secret to read. Defaults to
            the app-team SECRET_NAME env for back-compat.

    Returns:
        tuple: (webhook_url, hmac_secret) or raises if unavailable.
    """
    client = boto3.client("secretsmanager", region_name=REGION or None)
    try:
        response = client.get_secret_value(SecretId=secret_name)
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("ResourceNotFoundException", "InvalidRequestException"):
            raise SecretNotFoundError(
                f"Webhook credentials secret '{secret_name}' not found or not configured"
            ) from e
        raise

    secret_string = response.get("SecretString", "")
    if not secret_string:
        raise SecretNotFoundError(
            f"Webhook credentials secret '{secret_name}' has empty value"
        )

    payload = json.loads(secret_string)
    webhook_url = payload.get("webhook_url", "").strip()
    hmac_secret = payload.get("hmac_secret", "").strip()

    if not webhook_url or not hmac_secret:
        raise SecretNotFoundError(
            f"Webhook credentials secret '{secret_name}' is missing webhook_url or hmac_secret"
        )

    return webhook_url, hmac_secret


def select_destination(symptom):
    """Choose the delivery destination for a normalized symptom.

    Routing rule: alarms whose name starts with aiops-poc-be-infra- page the
    PLATFORM space (infra-owning, holds live BE telemetry). Everything else
    (FE golden signals, be-slo-* business SLOs) goes to the customer-facing
    app-team space.

    Returns:
        tuple: (destination_label, secret_name)
    """
    alarm_name = symptom.get("alarm_name", "") or ""
    if alarm_name.startswith(BE_INFRA_PREFIX):
        return "platform", PLATFORM_SECRET_NAME
    return "app-team", SECRET_NAME


def resolve_webhook_credentials(symptom):
    """Resolve (destination_label, webhook_url, hmac_secret) for a symptom.

    Routes by alarm name (select_destination). If the platform secret is
    chosen but unavailable/empty, fall back to the app-team secret and log a
    warning so nothing breaks before the platform webhook is registered. If
    the app-team secret is also unavailable, the SecretNotFoundError
    propagates (handler routes to DLQ, as before).
    """
    destination, secret_name = select_destination(symptom)
    try:
        webhook_url, hmac_secret = get_webhook_credentials(secret_name)
        return destination, webhook_url, hmac_secret
    except SecretNotFoundError as e:
        if secret_name != SECRET_NAME:
            logger.warning(
                "Platform webhook secret '%s' unavailable (%s) — falling back "
                "to the app-team secret for alarm '%s'",
                secret_name, str(e), symptom.get("alarm_name", "unknown"),
            )
            webhook_url, hmac_secret = get_webhook_credentials(SECRET_NAME)
            return "app-team (platform fallback)", webhook_url, hmac_secret
        raise


class SecretNotFoundError(Exception):
    """Raised when the webhook credentials secret is unavailable or incomplete."""
    pass


def normalize_payload(sns_message: dict) -> dict:
    """Normalize a CloudWatch Alarm SNS message into a clean business symptom.

    Handles both raw alarm JSON (NewStateValue, AlarmName, etc.) and already-
    structured messages from the incidents topics.

    Returns:
        dict with keys: source, alarm_name, state, reason, timestamp, account_id,
                        region, namespace, metric_name, dimensions
    """
    # SNS wraps the alarm data as a JSON string in "Message"
    message_body = sns_message.get("Message", "{}")
    if isinstance(message_body, str):
        try:
            message_body = json.loads(message_body)
        except (json.JSONDecodeError, TypeError):
            # Not JSON — treat as plain text symptom
            return {
                "source": sns_message.get("TopicArn", "unknown"),
                "alarm_name": "raw-message",
                "state": "UNKNOWN",
                "reason": message_body,
                "timestamp": sns_message.get("Timestamp", ""),
                "account_id": _extract_account_from_topic_arn(sns_message.get("TopicArn", "")),
                "region": REGION,
                "namespace": "",
                "metric_name": "",
                "dimensions": {},
            }

    # CloudWatch Alarm notification structure
    trigger = message_body.get("Trigger", {})
    dimensions_raw = trigger.get("Dimensions", [])
    dimensions = {d["name"]: d["value"] for d in dimensions_raw} if dimensions_raw else {}

    return {
        "source": sns_message.get("TopicArn", "unknown"),
        "alarm_name": message_body.get("AlarmName", "unknown"),
        "state": message_body.get("NewStateValue", "UNKNOWN"),
        "reason": message_body.get("NewStateReason", ""),
        "timestamp": message_body.get("StateChangeTime", sns_message.get("Timestamp", "")),
        "account_id": message_body.get("AWSAccountId", _extract_account_from_topic_arn(sns_message.get("TopicArn", ""))),
        "region": message_body.get("Region", REGION),
        "namespace": trigger.get("Namespace", ""),
        "metric_name": trigger.get("MetricName", ""),
        "dimensions": dimensions,
    }


def _extract_account_from_topic_arn(arn: str) -> str:
    """Extract account ID from an SNS topic ARN."""
    parts = arn.split(":")
    if len(parts) >= 5:
        return parts[4]
    return "unknown"


def build_incident_event(symptom: dict) -> dict:
    """Wrap a normalized symptom in the DevOps Agent incident event schema.

    The generic webhook expects a payload of the form:
        {eventType, incidentId, action, priority, title, description?,
         timestamp?, service?, data?}
    See "Invoking DevOps Agent through Webhook" in the DevOps Agent docs.

    IMPORTANT — action mapping: the Agent Space webhook only starts an
    investigation for action="created". Events with action="updated" (or
    "resolved") that reference an unknown incidentId are accepted with
    HTTP 200 but silently dropped — no investigation is triggered
    (verified empirically against the live webhook). So every alarm state
    that should be investigated MUST map to "created"; only OK (recovery)
    maps to "resolved".
    """
    incident_id = "{}-{}".format(
        symptom.get("alarm_name", "unknown"),
        symptom.get("timestamp", "") or datetime.now(timezone.utc).isoformat(),
    )
    return {
        "eventType": "incident",
        "incidentId": incident_id,
        "action": "resolved" if symptom.get("state") == "OK" else "created",
        "priority": "HIGH",
        "title": "{} is {}".format(symptom.get("alarm_name", "unknown"), symptom.get("state", "UNKNOWN")),
        "description": symptom.get("reason", ""),
        "timestamp": symptom.get("timestamp", ""),
        "service": symptom.get("dimensions", {}).get("Service", symptom.get("namespace", "")),
        "data": symptom,
    }


def sign_payload(payload: str, secret: str, timestamp: str) -> str:
    """Compute the DevOps Agent webhook HMAC-SHA256 signature.

    The generic (HMAC) webhook expects a base64-encoded HMAC-SHA256 digest
    of "<timestamp>:<body>" sent in the x-amzn-event-signature header,
    with the timestamp in x-amzn-event-timestamp.

    Args:
        payload: JSON request body to sign.
        secret: HMAC secret key (webhookSecret from the association).
        timestamp: ISO-8601 timestamp string included in the signature.

    Returns:
        Base64-encoded HMAC-SHA256 digest of "timestamp:payload".
    """
    digest = hmac.HMAC(
        secret.encode("utf-8"),
        f"{timestamp}:{payload}".encode("utf-8"),
        hashlib.sha256,
    ).digest()
    return base64.b64encode(digest).decode("utf-8")


def post_to_webhook(url: str, payload: str, signature: str, timestamp: str) -> int:
    """POST the signed payload to the webhook URL.

    Returns:
        HTTP status code.
    """
    headers = {
        "Content-Type": "application/json",
        "x-amzn-event-signature": signature,
        "x-amzn-event-timestamp": timestamp,
    }
    req = urllib.request.Request(url, data=payload.encode("utf-8"), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        logger.error("Webhook POST failed with HTTP %d: %s", e.code, e.reason)
        return e.code
    except urllib.error.URLError as e:
        logger.error("Webhook POST failed: %s", e.reason)
        return 0


def send_to_dlq(message: str, error_reason: str):
    """Send a failed message to the dead-letter queue with error context."""
    if not DLQ_URL:
        logger.error("DLQ_URL not configured — cannot send failed message")
        return

    sqs = boto3.client("sqs", region_name=REGION or None)
    sqs.send_message(
        QueueUrl=DLQ_URL,
        MessageBody=json.dumps({
            "error": error_reason,
            "original_message": message,
        }),
    )
    logger.info("Message sent to DLQ: %s", error_reason)


def handler(event, context):
    """Lambda entry point — processes SNS event records."""
    for record in event.get("Records", []):
        sns_message = record.get("Sns", {})
        raw_message = json.dumps(sns_message)

        # Normalize the alarm payload into a business symptom first — the
        # delivery destination (platform vs app-team space) is chosen by the
        # alarm name, so we must normalize before resolving credentials.
        symptom = normalize_payload(sns_message)

        try:
            destination, webhook_url, hmac_secret = resolve_webhook_credentials(symptom)
        except SecretNotFoundError as e:
            logger.warning("Secret unavailable: %s — routing to DLQ", str(e))
            send_to_dlq(raw_message, str(e))
            continue
        except Exception as e:
            logger.error("Unexpected error reading secret: %s", str(e))
            send_to_dlq(raw_message, f"Unexpected error: {str(e)}")
            continue

        # Wrap the symptom in the DevOps Agent incident event schema
        incident_event = build_incident_event(symptom)
        payload_json = json.dumps(incident_event)

        # Sign "timestamp:body" with HMAC-SHA256 (base64), per the DevOps
        # Agent generic webhook contract
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        signature = sign_payload(payload_json, hmac_secret, timestamp)

        # POST to webhook
        status = post_to_webhook(webhook_url, payload_json, signature, timestamp)
        if status and 200 <= status < 300:
            logger.info(
                "Successfully delivered alarm '%s' to %s space webhook",
                symptom["alarm_name"], destination,
            )
        else:
            error_msg = (
                f"Webhook delivery failed (HTTP {status}) for alarm "
                f"'{symptom['alarm_name']}' (destination: {destination})"
            )
            logger.error(error_msg)
            send_to_dlq(raw_message, error_msg)

    return {"statusCode": 200, "body": "processed"}
