"""Unit tests for the webhook bridge Lambda handler.

Tests payload normalization, HMAC signing, and missing-secret handling.
"""

import base64
import hashlib
import hmac
import json
import os
from unittest.mock import MagicMock, patch

import pytest

# Set env vars before importing handler
os.environ["SECRET_NAME"] = "aiops-poc/webhook-credentials"  # nosec B105  # Secrets Manager secret NAME, not a credential value
os.environ["DLQ_URL"] = "https://sqs.us-east-1.amazonaws.com/333333333333/webhook-bridge-dlq"
os.environ["AWS_REGION"] = "us-east-1"

os.environ["PLATFORM_SECRET_NAME"] = "aiops-poc/platform-webhook-credentials"  # nosec B105  # Secrets Manager secret NAME, not a credential value

from handler import (
    SecretNotFoundError,
    build_incident_event,
    normalize_payload,
    resolve_webhook_credentials,
    select_destination,
    sign_payload,
    handler,
    _extract_account_from_topic_arn,
)


# ─────────────────────────────────────────────────────────────────────────────
# Payload normalization tests
# ─────────────────────────────────────────────────────────────────────────────

class TestNormalizePayload:
    """Tests for normalize_payload converting CloudWatch alarm JSON to business symptom."""

    def test_cloudwatch_alarm_full(self):
        """Full CloudWatch alarm structure is normalized correctly."""
        alarm_body = {
            "AlarmName": "aiops-poc-checkout-latency-p99",
            "NewStateValue": "ALARM",
            "NewStateReason": "Threshold Crossed: 1 out of 1 datapoints [2500.0] was >= 2000",
            "StateChangeTime": "2024-01-15T10:30:00.000+0000",
            "AWSAccountId": "111111111111",
            "Region": "EU (Frankfurt)",
            "Trigger": {
                "Namespace": "ApplicationSignals",
                "MetricName": "Latency",
                "Dimensions": [
                    {"name": "Service", "value": "payforadoption"},
                    {"name": "Operation", "value": "POST /api/completionadoption"},
                ],
            },
        }

        sns_message = {
            "TopicArn": "arn:aws:sns:us-east-1:111111111111:aiops-poc-incidents",
            "Timestamp": "2024-01-15T10:30:01.000Z",
            "Message": json.dumps(alarm_body),
        }

        result = normalize_payload(sns_message)

        assert result["source"] == "arn:aws:sns:us-east-1:111111111111:aiops-poc-incidents"
        assert result["alarm_name"] == "aiops-poc-checkout-latency-p99"
        assert result["state"] == "ALARM"
        assert "Threshold Crossed" in result["reason"]
        assert result["account_id"] == "111111111111"
        assert result["namespace"] == "ApplicationSignals"
        assert result["metric_name"] == "Latency"
        assert result["dimensions"]["Service"] == "payforadoption"

    def test_cloudwatch_alarm_minimal(self):
        """Alarm with minimal fields still normalizes."""
        alarm_body = {
            "AlarmName": "some-alarm",
            "NewStateValue": "OK",
        }

        sns_message = {
            "TopicArn": "arn:aws:sns:us-east-1:222222222222:aiops-poc-fe-incidents",
            "Message": json.dumps(alarm_body),
        }

        result = normalize_payload(sns_message)

        assert result["alarm_name"] == "some-alarm"
        assert result["state"] == "OK"
        assert result["namespace"] == ""
        assert result["dimensions"] == {}

    def test_plain_text_message(self):
        """Non-JSON Message field is treated as raw symptom."""
        sns_message = {
            "TopicArn": "arn:aws:sns:us-east-1:111111111111:aiops-poc-incidents",
            "Timestamp": "2024-01-15T12:00:00.000Z",
            "Message": "Service is experiencing high error rate",
        }

        result = normalize_payload(sns_message)

        assert result["alarm_name"] == "raw-message"
        assert result["state"] == "UNKNOWN"
        assert result["reason"] == "Service is experiencing high error rate"
        assert result["account_id"] == "111111111111"

    def test_empty_message(self):
        """Empty message field."""
        sns_message = {
            "TopicArn": "arn:aws:sns:us-east-1:111111111111:aiops-poc-incidents",
            "Message": "",
        }

        result = normalize_payload(sns_message)

        # Empty string is not valid JSON, treated as plain text
        assert result["alarm_name"] == "raw-message"
        assert result["reason"] == ""

    def test_fe_account_extraction(self):
        """Account extracted from FE topic ARN."""
        sns_message = {
            "TopicArn": "arn:aws:sns:us-east-1:222222222222:aiops-poc-fe-incidents",
            "Message": json.dumps({"AlarmName": "journey-canary-slo"}),
        }

        result = normalize_payload(sns_message)
        # AWSAccountId not in body, falls through to ARN extraction
        assert result["account_id"] == "222222222222"


class TestExtractAccountFromTopicArn:
    """Tests for ARN account extraction helper."""

    def test_valid_arn(self):
        assert _extract_account_from_topic_arn("arn:aws:sns:us-east-1:111111111111:topic") == "111111111111"

    def test_invalid_arn(self):
        assert _extract_account_from_topic_arn("not-an-arn") == "unknown"

    def test_empty_arn(self):
        assert _extract_account_from_topic_arn("") == "unknown"


# ─────────────────────────────────────────────────────────────────────────────
# Incident event action mapping tests
# ─────────────────────────────────────────────────────────────────────────────

class TestBuildIncidentEventAction:
    """The Agent Space webhook only starts an investigation for action='created'.

    action='updated' with an unknown incidentId is accepted (HTTP 200) but
    silently dropped, so any state that warrants investigation MUST map to
    'created'. Only OK (recovery) maps to 'resolved'.
    """

    @staticmethod
    def _symptom(state):
        return {
            "alarm_name": "test-alarm",
            "state": state,
            "reason": "reason",
            "timestamp": "2024-01-15T10:30:00Z",
            "dimensions": {},
            "namespace": "AWS/ECS",
        }

    def test_alarm_state_maps_to_created(self):
        assert build_incident_event(self._symptom("ALARM"))["action"] == "created"

    def test_ok_state_maps_to_resolved(self):
        assert build_incident_event(self._symptom("OK"))["action"] == "resolved"

    def test_unknown_state_maps_to_created(self):
        """Synthetic/non-alarm events (e.g. smoke test) must still trigger
        an investigation — 'updated' would be silently dropped."""
        assert build_incident_event(self._symptom("UNKNOWN"))["action"] == "created"

    def test_insufficient_data_maps_to_created(self):
        assert build_incident_event(self._symptom("INSUFFICIENT_DATA"))["action"] == "created"

    def test_never_emits_updated(self):
        """No alarm state may produce 'updated' — it never triggers anything."""
        for state in ("ALARM", "OK", "UNKNOWN", "INSUFFICIENT_DATA", ""):
            assert build_incident_event(self._symptom(state))["action"] != "updated"


# ─────────────────────────────────────────────────────────────────────────────
# Dual-path routing tests (platform vs app-team space)
# ─────────────────────────────────────────────────────────────────────────────

APP_TEAM_SECRET = "aiops-poc/webhook-credentials"  # nosec B105  # secret NAME, not a credential value
PLATFORM_SECRET = "aiops-poc/platform-webhook-credentials"  # nosec B105  # secret NAME, not a credential value


class TestSelectDestination:
    """Alarm-name routing: aiops-poc-be-infra-* → platform, else app-team."""

    def test_be_infra_payments_tasks_routes_to_platform(self):
        dest, secret = select_destination({"alarm_name": "aiops-poc-be-infra-payments-tasks"})
        assert dest == "platform"
        assert secret == PLATFORM_SECRET

    def test_any_be_infra_prefix_routes_to_platform(self):
        for name in (
            "aiops-poc-be-infra-search-tasks",
            "aiops-poc-be-infra-payments-cpu",
            "aiops-poc-be-infra-payments-memory",
        ):
            dest, secret = select_destination({"alarm_name": name})
            assert dest == "platform", name
            assert secret == PLATFORM_SECRET, name

    def test_fe_golden_routes_to_app_team(self):
        dest, secret = select_destination({"alarm_name": "aiops-poc-fe-golden-journey-success"})
        assert dest == "app-team"
        assert secret == APP_TEAM_SECRET

    def test_be_slo_statusupdate_lag_routes_to_app_team(self):
        dest, secret = select_destination({"alarm_name": "aiops-poc-be-slo-statusupdate-lag"})
        assert dest == "app-team"
        assert secret == APP_TEAM_SECRET

    def test_missing_alarm_name_routes_to_app_team(self):
        dest, secret = select_destination({})
        assert dest == "app-team"
        assert secret == APP_TEAM_SECRET


class TestResolveWebhookCredentials:
    """resolve_webhook_credentials picks the right secret and falls back."""

    @staticmethod
    def _mock_sm(secret_values):
        """secret_values: dict of secret_name -> SecretString (or a ClientError)."""
        from botocore.exceptions import ClientError

        mock_sm = MagicMock()

        def get_secret_value(SecretId):
            val = secret_values.get(SecretId)
            if val is None:
                raise ClientError(
                    {"Error": {"Code": "ResourceNotFoundException", "Message": "not found"}},
                    "GetSecretValue",
                )
            return {"SecretString": val}

        mock_sm.get_secret_value.side_effect = get_secret_value
        return mock_sm

    @patch("handler.boto3.client")
    def test_platform_alarm_uses_platform_secret(self, mock_boto_client):
        mock_sm = self._mock_sm({
            PLATFORM_SECRET: json.dumps({"webhook_url": "https://platform.example", "hmac_secret": "psec"}),  # nosec B105  # fake HMAC secret in a test fixture, never a real credential
            APP_TEAM_SECRET: json.dumps({"webhook_url": "https://appteam.example", "hmac_secret": "asec"}),  # nosec B105  # fake HMAC secret in a test fixture, never a real credential
        })
        mock_boto_client.return_value = mock_sm

        dest, url, secret = resolve_webhook_credentials(
            {"alarm_name": "aiops-poc-be-infra-payments-tasks"})
        assert dest == "platform"
        assert url == "https://platform.example"
        assert secret == "psec"  # nosec B105  # fake HMAC secret from the mocked Secrets Manager fixture

    @patch("handler.boto3.client")
    def test_app_team_alarm_uses_app_team_secret(self, mock_boto_client):
        mock_sm = self._mock_sm({
            PLATFORM_SECRET: json.dumps({"webhook_url": "https://platform.example", "hmac_secret": "psec"}),  # nosec B105  # fake HMAC secret in a test fixture, never a real credential
            APP_TEAM_SECRET: json.dumps({"webhook_url": "https://appteam.example", "hmac_secret": "asec"}),  # nosec B105  # fake HMAC secret in a test fixture, never a real credential
        })
        mock_boto_client.return_value = mock_sm

        for name in ("aiops-poc-fe-golden-checkout-error-rate",
                     "aiops-poc-be-slo-statusupdate-lag"):
            dest, url, secret = resolve_webhook_credentials({"alarm_name": name})
            assert dest == "app-team", name
            assert url == "https://appteam.example", name
            assert secret == "asec", name  # nosec B105  # fake HMAC secret from the mocked Secrets Manager fixture

    @patch("handler.boto3.client")
    def test_platform_secret_missing_falls_back_to_app_team(self, mock_boto_client):
        # Platform secret does not exist yet — must fall back to app-team.
        mock_sm = self._mock_sm({
            APP_TEAM_SECRET: json.dumps({"webhook_url": "https://appteam.example", "hmac_secret": "asec"}),  # nosec B105  # fake HMAC secret in a test fixture, never a real credential
        })
        mock_boto_client.return_value = mock_sm

        dest, url, secret = resolve_webhook_credentials(
            {"alarm_name": "aiops-poc-be-infra-payments-tasks"})
        assert "app-team" in dest
        assert "fallback" in dest
        assert url == "https://appteam.example"
        assert secret == "asec"  # nosec B105  # fake HMAC secret from the mocked Secrets Manager fixture

    @patch("handler.boto3.client")
    def test_both_secrets_missing_raises(self, mock_boto_client):
        # Neither secret exists — SecretNotFoundError must propagate (→ DLQ).
        mock_sm = self._mock_sm({})
        mock_boto_client.return_value = mock_sm

        with pytest.raises(SecretNotFoundError):
            resolve_webhook_credentials({"alarm_name": "aiops-poc-be-infra-payments-tasks"})


# ─────────────────────────────────────────────────────────────────────────────
# HMAC signing tests
# ─────────────────────────────────────────────────────────────────────────────

class TestSignPayload:
    """Tests for the DevOps Agent webhook HMAC-SHA256 signing (base64 of timestamp:body)."""

    def test_known_signature(self):
        """Verify HMAC output matches a known computation over 'timestamp:body'."""
        payload = '{"alarm_name": "test"}'
        secret = "my-secret-key"  # nosec B105  # literal test vector for a known-answer HMAC test
        timestamp = "2024-01-15T10:30:00.000Z"

        expected = base64.b64encode(
            hmac.HMAC(
                secret.encode("utf-8"),
                f"{timestamp}:{payload}".encode("utf-8"),
                hashlib.sha256,
            ).digest()
        ).decode("utf-8")

        result = sign_payload(payload, secret, timestamp)
        assert result == expected

    def test_different_payloads_different_sigs(self):
        """Different payloads produce different signatures."""
        secret = "secret"  # nosec B105  # literal test vector, only needs to be non-empty
        ts = "2024-01-15T10:30:00.000Z"
        sig1 = sign_payload("payload1", secret, ts)
        sig2 = sign_payload("payload2", secret, ts)
        assert sig1 != sig2

    def test_different_secrets_different_sigs(self):
        """Different secrets produce different signatures."""
        payload = "same-payload"
        ts = "2024-01-15T10:30:00.000Z"
        sig1 = sign_payload(payload, "secret1", ts)
        sig2 = sign_payload(payload, "secret2", ts)
        assert sig1 != sig2

    def test_different_timestamps_different_sigs(self):
        """The timestamp is part of the signed content."""
        sig1 = sign_payload("data", "key", "2024-01-15T10:30:00.000Z")
        sig2 = sign_payload("data", "key", "2024-01-15T10:30:01.000Z")
        assert sig1 != sig2

    def test_signature_is_base64(self):
        """Signature is base64 (decodes to a 32-byte SHA-256 digest)."""
        sig = sign_payload("data", "key", "2024-01-15T10:30:00.000Z")
        assert len(base64.b64decode(sig)) == 32


# ─────────────────────────────────────────────────────────────────────────────
# Missing secret handling tests
# ─────────────────────────────────────────────────────────────────────────────

class TestMissingSecretHandling:
    """Tests that the handler gracefully sends to DLQ when secret is unavailable."""

    @patch("handler.boto3.client")
    def test_secret_not_found_sends_to_dlq(self, mock_boto_client):
        """When secret doesn't exist, message goes to DLQ."""
        from botocore.exceptions import ClientError

        # Mock SecretsManager raising ResourceNotFoundException
        mock_sm = MagicMock()
        mock_sm.get_secret_value.side_effect = ClientError(
            {"Error": {"Code": "ResourceNotFoundException", "Message": "not found"}},
            "GetSecretValue",
        )

        # Mock SQS for DLQ
        mock_sqs = MagicMock()

        def client_factory(service, **kwargs):
            if service == "secretsmanager":
                return mock_sm
            elif service == "sqs":
                return mock_sqs
            return MagicMock()

        mock_boto_client.side_effect = client_factory

        event = {
            "Records": [
                {
                    "Sns": {
                        "TopicArn": "arn:aws:sns:us-east-1:111111111111:aiops-poc-incidents",
                        "Message": json.dumps({"AlarmName": "test-alarm", "NewStateValue": "ALARM"}),
                        "Timestamp": "2024-01-15T10:00:00Z",
                    }
                }
            ]
        }

        result = handler(event, None)

        assert result["statusCode"] == 200
        mock_sqs.send_message.assert_called_once()
        call_kwargs = mock_sqs.send_message.call_args[1]
        assert "aiops-poc/webhook-credentials" in call_kwargs["MessageBody"]
        assert "not found" in call_kwargs["MessageBody"] or "not configured" in call_kwargs["MessageBody"]

    @patch("handler.boto3.client")
    def test_empty_secret_sends_to_dlq(self, mock_boto_client):
        """When secret value is empty, message goes to DLQ."""
        mock_sm = MagicMock()
        mock_sm.get_secret_value.return_value = {"SecretString": ""}

        mock_sqs = MagicMock()

        def client_factory(service, **kwargs):
            if service == "secretsmanager":
                return mock_sm
            elif service == "sqs":
                return mock_sqs
            return MagicMock()

        mock_boto_client.side_effect = client_factory

        event = {
            "Records": [
                {
                    "Sns": {
                        "TopicArn": "arn:aws:sns:us-east-1:222222222222:aiops-poc-fe-incidents",
                        "Message": "test",
                        "Timestamp": "2024-01-15T10:00:00Z",
                    }
                }
            ]
        }

        result = handler(event, None)
        mock_sqs.send_message.assert_called_once()

    @patch("handler.boto3.client")
    def test_incomplete_secret_sends_to_dlq(self, mock_boto_client):
        """When secret exists but missing fields, message goes to DLQ."""
        mock_sm = MagicMock()
        mock_sm.get_secret_value.return_value = {
            "SecretString": json.dumps({"webhook_url": "https://example.com", "hmac_secret": ""})  # nosec B105  # fake HMAC secret in a test fixture, never a real credential
        }

        mock_sqs = MagicMock()

        def client_factory(service, **kwargs):
            if service == "secretsmanager":
                return mock_sm
            elif service == "sqs":
                return mock_sqs
            return MagicMock()

        mock_boto_client.side_effect = client_factory

        event = {
            "Records": [
                {
                    "Sns": {
                        "TopicArn": "arn:aws:sns:us-east-1:111111111111:aiops-poc-incidents",
                        "Message": json.dumps({"AlarmName": "x"}),
                        "Timestamp": "2024-01-15T10:00:00Z",
                    }
                }
            ]
        }

        result = handler(event, None)
        mock_sqs.send_message.assert_called_once()
        body = json.loads(mock_sqs.send_message.call_args[1]["MessageBody"])
        assert "missing" in body["error"].lower() or "hmac_secret" in body["error"]


# ─────────────────────────────────────────────────────────────────────────────
# Happy path (end-to-end with mocked external calls)
# ─────────────────────────────────────────────────────────────────────────────

class TestHappyPath:
    """Tests that the handler correctly posts a signed payload when secret is available."""

    @patch("handler.urllib.request.urlopen")
    @patch("handler.boto3.client")
    def test_successful_delivery(self, mock_boto_client, mock_urlopen):
        """Valid secret → normalized payload POSTed with correct signature."""
        secret_val = json.dumps({
            "webhook_url": "https://webhook.example.com/ingest",
            "hmac_secret": "test-hmac-key-123",  # nosec B105  # fake HMAC secret in a test fixture, never a real credential
        })

        mock_sm = MagicMock()
        mock_sm.get_secret_value.return_value = {"SecretString": secret_val}

        def client_factory(service, **kwargs):
            if service == "secretsmanager":
                return mock_sm
            return MagicMock()

        mock_boto_client.side_effect = client_factory

        # Mock successful HTTP response
        mock_response = MagicMock()
        mock_response.status = 200
        mock_response.__enter__ = lambda s: s
        mock_response.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_response

        event = {
            "Records": [
                {
                    "Sns": {
                        "TopicArn": "arn:aws:sns:us-east-1:111111111111:aiops-poc-incidents",
                        "Message": json.dumps({
                            "AlarmName": "aiops-poc-checkout-latency-p99",
                            "NewStateValue": "ALARM",
                            "NewStateReason": "p99 > 2000ms",
                            "StateChangeTime": "2024-01-15T10:30:00Z",
                            "AWSAccountId": "111111111111",
                            "Region": "EU (Frankfurt)",
                            "Trigger": {
                                "Namespace": "ApplicationSignals",
                                "MetricName": "Latency",
                                "Dimensions": [],
                            },
                        }),
                        "Timestamp": "2024-01-15T10:30:01Z",
                    }
                }
            ]
        }

        result = handler(event, None)

        assert result["statusCode"] == 200
        mock_urlopen.assert_called_once()

        # Verify the request was constructed correctly
        request_obj = mock_urlopen.call_args[0][0]
        assert request_obj.full_url == "https://webhook.example.com/ingest"
        # urllib.request normalizes header keys to Title-case
        assert "X-amzn-event-signature" in request_obj.headers
        assert "X-amzn-event-timestamp" in request_obj.headers

        # Body follows the DevOps Agent incident event schema
        posted_body = request_obj.data.decode("utf-8")
        incident = json.loads(posted_body)
        assert incident["eventType"] == "incident"
        assert incident["action"] == "created"  # NewStateValue == ALARM
        assert "aiops-poc-checkout-latency-p99" in incident["title"]
        assert incident["data"]["alarm_name"] == "aiops-poc-checkout-latency-p99"

        # Verify signature covers "timestamp:body" (base64 HMAC-SHA256)
        ts = request_obj.headers["X-amzn-event-timestamp"]
        expected_sig = base64.b64encode(
            hmac.HMAC(
                b"test-hmac-key-123",
                f"{ts}:{posted_body}".encode("utf-8"),
                hashlib.sha256,
            ).digest()
        ).decode("utf-8")
        assert request_obj.headers["X-amzn-event-signature"] == expected_sig

    @patch("handler.urllib.request.urlopen")
    @patch("handler.boto3.client")
    def test_be_infra_alarm_delivered_to_platform_webhook(self, mock_boto_client, mock_urlopen):
        """A be-infra-* alarm is POSTed to the PLATFORM webhook URL/secret."""
        secrets = {
            "aiops-poc/platform-webhook-credentials": json.dumps({
                "webhook_url": "https://platform.example/ingest",
                "hmac_secret": "platform-key",  # nosec B105  # fake HMAC secret in a test fixture, never a real credential
            }),
            "aiops-poc/webhook-credentials": json.dumps({
                "webhook_url": "https://appteam.example/ingest",
                "hmac_secret": "appteam-key",  # nosec B105  # fake HMAC secret in a test fixture, never a real credential
            }),
        }

        mock_sm = MagicMock()
        mock_sm.get_secret_value.side_effect = lambda SecretId: {"SecretString": secrets[SecretId]}

        def client_factory(service, **kwargs):
            if service == "secretsmanager":
                return mock_sm
            return MagicMock()

        mock_boto_client.side_effect = client_factory

        mock_response = MagicMock()
        mock_response.status = 200
        mock_response.__enter__ = lambda s: s
        mock_response.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_response

        event = {
            "Records": [
                {
                    "Sns": {
                        "TopicArn": "arn:aws:sns:us-east-1:111111111111:aiops-poc-incidents",
                        "Message": json.dumps({
                            "AlarmName": "aiops-poc-be-infra-payments-tasks",
                            "NewStateValue": "ALARM",
                            "NewStateReason": "RunningTaskCount < 1",
                            "StateChangeTime": "2024-01-15T10:30:00Z",
                            "AWSAccountId": "111111111111",
                            "Trigger": {
                                "Namespace": "ECS/ContainerInsights",
                                "MetricName": "RunningTaskCount",
                                "Dimensions": [],
                            },
                        }),
                        "Timestamp": "2024-01-15T10:30:01Z",
                    }
                }
            ]
        }

        result = handler(event, None)
        assert result["statusCode"] == 200
        mock_urlopen.assert_called_once()

        request_obj = mock_urlopen.call_args[0][0]
        # Delivered to the platform webhook, signed with the platform secret.
        assert request_obj.full_url == "https://platform.example/ingest"
        ts = request_obj.headers["X-amzn-event-timestamp"]
        posted_body = request_obj.data.decode("utf-8")
        expected_sig = base64.b64encode(
            hmac.HMAC(
                b"platform-key",
                f"{ts}:{posted_body}".encode("utf-8"),
                hashlib.sha256,
            ).digest()
        ).decode("utf-8")
        assert request_obj.headers["X-amzn-event-signature"] == expected_sig
