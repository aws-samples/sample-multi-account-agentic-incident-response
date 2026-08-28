"""Tests for the runtime resource resolver.

Every resource whose physical name CloudFormation generates is resolved here,
so this file covers the four behaviours the resolution contract rests on:

  * a caller-supplied value wins outright and costs no AWS call;
  * an SSM hit yields the deployment's real value;
  * an SSM miss raises an actionable error — never a stale literal — and the
    message names the parameter, the account, the region, and the argument that
    bypasses the lookup;
  * a resolved value is cached for the process, so a second call makes no
    second AWS call.

All AWS calls are mocked. The suite needs no credentials, and every value it
uses is synthetic with the same shape as the real thing.
"""

from unittest.mock import MagicMock, patch

import pytest

from src import resource_resolver as rr
from src.config import BE_ACCOUNT_ID, REGION

# Synthetic values, same shape as the CloudFormation-generated originals.
TABLE_NAME = "DevStorageStack-DynamoDbddbPetadoption-Sy1Th3T1cAbc"
QUEUE_NAME = "DevCoreStack-QueueResourcessqspetadoption-Sy1Th3T1cAbc"
QUEUE_URL = f"https://sqs.{REGION}.amazonaws.com/{BE_ACCOUNT_ID}/{QUEUE_NAME}"
QUEUE_ARN = f"arn:aws:sqs:{REGION}:{BE_ACCOUNT_ID}:{QUEUE_NAME}"
CLUSTER_ID = "devstoragestack-auroradatabase-sy1th3t1cabc"
WRITER_ENDPOINT = f"{CLUSTER_ID}.cluster-c9xmpl.{REGION}.rds.amazonaws.com"
FUNCTION_NAME = "DevCoreStack-StatusUpdater-Sy1Th3T1cAbc"
FUNCTION_ARN = f"arn:aws:lambda:{REGION}:{BE_ACCOUNT_ID}:function:{FUNCTION_NAME}"


class ParameterNotFound(Exception):
    """Stands in for the botocore ParameterNotFound the resolver catches."""


@pytest.fixture(autouse=True)
def _clear_cache():
    """The cache is process-wide by design; no test may inherit another's."""
    rr.clear_cache()
    yield
    rr.clear_cache()


def _ssm_returning(value):
    client = MagicMock()
    client.get_parameter.return_value = {"Parameter": {"Value": value}}
    return client


def _ssm_missing():
    client = MagicMock()
    client.get_parameter.side_effect = ParameterNotFound(
        "ParameterNotFound: /petstore/whatever"
    )
    return client


# ─── Caller-supplied wins ────────────────────────────────────────────────────


class TestExplicitValueWins:
    @patch("src.resource_resolver.get_client")
    def test_table_name_wins_without_any_aws_call(self, mock_get_client):
        assert rr.resolve_adoptions_table("my-table") == "my-table"
        mock_get_client.assert_not_called()

    @patch("src.resource_resolver.get_client")
    def test_queue_name_wins_and_is_turned_into_a_url(self, mock_get_client):
        url, name = rr.resolve_status_update_queue(QUEUE_NAME)
        assert name == QUEUE_NAME
        assert url == QUEUE_URL
        mock_get_client.assert_not_called()

    @patch("src.resource_resolver.get_client")
    def test_queue_url_wins_and_is_used_verbatim(self, mock_get_client):
        url, name = rr.resolve_status_update_queue(QUEUE_URL)
        assert url == QUEUE_URL
        assert name == QUEUE_NAME
        mock_get_client.assert_not_called()

    @patch("src.resource_resolver.get_client")
    def test_cluster_id_wins_without_any_aws_call(self, mock_get_client):
        assert rr.resolve_rds_cluster_id(CLUSTER_ID) == CLUSTER_ID
        mock_get_client.assert_not_called()

    @patch("src.resource_resolver.get_client")
    def test_writer_endpoint_yields_the_identifier(self, mock_get_client):
        assert rr.resolve_rds_cluster_id(WRITER_ENDPOINT) == CLUSTER_ID
        mock_get_client.assert_not_called()

    @patch("src.resource_resolver.get_client")
    def test_function_name_wins_without_any_aws_call(self, mock_get_client):
        assert rr.resolve_status_updater_function_name(FUNCTION_NAME) == FUNCTION_NAME
        mock_get_client.assert_not_called()

    @patch("src.resource_resolver.get_client")
    def test_blank_explicit_value_is_not_a_value(self, mock_get_client):
        """A whitespace-only argument falls through to the lookup, not past it."""
        mock_get_client.return_value = _ssm_returning(TABLE_NAME)
        assert rr.resolve_adoptions_table("   ") == TABLE_NAME
        mock_get_client.assert_called_once_with("ssm")


# ─── SSM hit ─────────────────────────────────────────────────────────────────


class TestSsmHit:
    @patch("src.resource_resolver.get_client")
    def test_table_comes_from_the_upstream_parameter(self, mock_get_client):
        ssm = _ssm_returning(TABLE_NAME)
        mock_get_client.return_value = ssm

        assert rr.resolve_adoptions_table() == TABLE_NAME
        ssm.get_parameter.assert_called_once_with(
            Name=rr.ADOPTIONS_TABLE_PARAMETER
        )

    @patch("src.resource_resolver.get_client")
    def test_queue_url_comes_from_the_upstream_parameter(self, mock_get_client):
        ssm = _ssm_returning(QUEUE_URL)
        mock_get_client.return_value = ssm

        url, name = rr.resolve_status_update_queue()

        assert (url, name) == (QUEUE_URL, QUEUE_NAME)
        ssm.get_parameter.assert_called_once_with(
            Name=rr.STATUS_UPDATE_QUEUE_PARAMETER
        )

    @patch("src.resource_resolver.get_client")
    def test_cluster_id_is_read_out_of_the_writer_endpoint(self, mock_get_client):
        ssm = _ssm_returning(WRITER_ENDPOINT)
        mock_get_client.return_value = ssm

        assert rr.resolve_rds_cluster_id() == CLUSTER_ID
        ssm.get_parameter.assert_called_once_with(
            Name=rr.RDS_WRITER_ENDPOINT_PARAMETER
        )

    @patch("src.resource_resolver.get_client")
    def test_status_updater_comes_from_the_queue_event_source_mapping(
        self, mock_get_client
    ):
        """No parameter publishes the name, so the account is asked instead."""
        ssm = _ssm_returning(QUEUE_URL)
        sqs = MagicMock()
        sqs.get_queue_attributes.return_value = {"Attributes": {"QueueArn": QUEUE_ARN}}
        lam = MagicMock()
        lam.list_event_source_mappings.return_value = {
            "EventSourceMappings": [{"FunctionArn": FUNCTION_ARN}]
        }
        clients = {"ssm": ssm, "sqs": sqs, "lambda": lam}
        mock_get_client.side_effect = lambda name: clients[name]

        assert rr.resolve_status_updater_function_name() == FUNCTION_NAME
        lam.list_event_source_mappings.assert_called_once_with(
            EventSourceArn=QUEUE_ARN
        )

    @patch("src.resource_resolver.get_client")
    def test_empty_parameter_value_is_treated_as_missing(self, mock_get_client):
        mock_get_client.return_value = _ssm_returning("   ")

        with pytest.raises(rr.ResourceResolutionError) as excinfo:
            rr.resolve_adoptions_table()

        assert "empty" in str(excinfo.value)


# ─── SSM miss produces an actionable error ───────────────────────────────────


class TestSsmMissIsActionable:
    @patch("src.resource_resolver.get_client")
    def test_message_names_parameter_account_region_and_bypass(self, mock_get_client):
        mock_get_client.return_value = _ssm_missing()

        with pytest.raises(rr.ResourceResolutionError) as excinfo:
            rr.resolve_adoptions_table()

        message = str(excinfo.value)
        assert rr.ADOPTIONS_TABLE_PARAMETER in message
        assert BE_ACCOUNT_ID in message
        assert REGION in message
        assert "table_name=" in message
        assert "ParameterNotFound" in message

    @patch("src.resource_resolver.get_client")
    def test_queue_message_names_its_own_bypass_argument(self, mock_get_client):
        mock_get_client.return_value = _ssm_missing()

        with pytest.raises(rr.ResourceResolutionError) as excinfo:
            rr.resolve_status_update_queue()

        message = str(excinfo.value)
        assert rr.STATUS_UPDATE_QUEUE_PARAMETER in message
        assert "queue_name=" in message

    @patch("src.resource_resolver.get_client")
    def test_cluster_message_names_its_own_bypass_argument(self, mock_get_client):
        mock_get_client.return_value = _ssm_missing()

        with pytest.raises(rr.ResourceResolutionError) as excinfo:
            rr.resolve_rds_cluster_id()

        message = str(excinfo.value)
        assert rr.RDS_WRITER_ENDPOINT_PARAMETER in message
        assert "cluster_id=" in message

    @patch("src.resource_resolver.get_client")
    def test_no_event_source_mapping_names_the_queue_parameter(self, mock_get_client):
        ssm = _ssm_returning(QUEUE_URL)
        sqs = MagicMock()
        sqs.get_queue_attributes.return_value = {"Attributes": {"QueueArn": QUEUE_ARN}}
        lam = MagicMock()
        lam.list_event_source_mappings.return_value = {"EventSourceMappings": []}
        clients = {"ssm": ssm, "sqs": sqs, "lambda": lam}
        mock_get_client.side_effect = lambda name: clients[name]

        with pytest.raises(rr.ResourceResolutionError) as excinfo:
            rr.resolve_status_updater_function_name()

        message = str(excinfo.value)
        assert rr.STATUS_UPDATE_QUEUE_PARAMETER in message
        assert QUEUE_ARN in message
        assert "function_name=" in message

    @patch("src.resource_resolver.get_client")
    def test_a_custom_endpoint_is_rejected_rather_than_guessed_at(
        self, mock_get_client
    ):
        endpoint = f"myreports.cluster-custom-c9xmpl.{REGION}.rds.amazonaws.com"

        with pytest.raises(rr.ResourceResolutionError) as excinfo:
            rr.resolve_rds_cluster_id(endpoint)

        assert "cannot derive a DB cluster identifier" in str(excinfo.value)
        mock_get_client.assert_not_called()

    @patch("src.resource_resolver.get_client")
    def test_a_failed_lookup_is_not_cached(self, mock_get_client):
        """A backend deploy finishing later must be picked up, not shadowed."""
        ssm = MagicMock()
        ssm.get_parameter.side_effect = [
            ParameterNotFound("ParameterNotFound"),
            {"Parameter": {"Value": TABLE_NAME}},
        ]
        mock_get_client.return_value = ssm

        with pytest.raises(rr.ResourceResolutionError):
            rr.resolve_adoptions_table()
        assert rr.resolve_adoptions_table() == TABLE_NAME


# ─── Cache ───────────────────────────────────────────────────────────────────


class TestCache:
    @patch("src.resource_resolver.get_client")
    def test_repeat_table_resolution_makes_no_second_call(self, mock_get_client):
        ssm = _ssm_returning(TABLE_NAME)
        mock_get_client.return_value = ssm

        first = rr.resolve_adoptions_table()
        second = rr.resolve_adoptions_table()

        assert first == second == TABLE_NAME
        ssm.get_parameter.assert_called_once()
        mock_get_client.assert_called_once_with("ssm")

    @patch("src.resource_resolver.get_client")
    def test_repeat_queue_resolution_makes_no_second_call(self, mock_get_client):
        ssm = _ssm_returning(QUEUE_URL)
        mock_get_client.return_value = ssm

        rr.resolve_status_update_queue()
        rr.resolve_status_update_queue()

        ssm.get_parameter.assert_called_once()

    @patch("src.resource_resolver.get_client")
    def test_repeat_cluster_resolution_makes_no_second_call(self, mock_get_client):
        ssm = _ssm_returning(WRITER_ENDPOINT)
        mock_get_client.return_value = ssm

        rr.resolve_rds_cluster_id()
        rr.resolve_rds_cluster_id()

        ssm.get_parameter.assert_called_once()

    @patch("src.resource_resolver.get_client")
    def test_repeat_function_resolution_makes_no_second_lookup(self, mock_get_client):
        ssm = _ssm_returning(QUEUE_URL)
        sqs = MagicMock()
        sqs.get_queue_attributes.return_value = {"Attributes": {"QueueArn": QUEUE_ARN}}
        lam = MagicMock()
        lam.list_event_source_mappings.return_value = {
            "EventSourceMappings": [{"FunctionArn": FUNCTION_ARN}]
        }
        clients = {"ssm": ssm, "sqs": sqs, "lambda": lam}
        mock_get_client.side_effect = lambda name: clients[name]

        rr.resolve_status_updater_function_name()
        rr.resolve_status_updater_function_name()

        ssm.get_parameter.assert_called_once()
        sqs.get_queue_attributes.assert_called_once()
        lam.list_event_source_mappings.assert_called_once()

    @patch("src.resource_resolver.get_client")
    def test_clear_cache_forces_a_re_read(self, mock_get_client):
        ssm = MagicMock()
        ssm.get_parameter.side_effect = [
            {"Parameter": {"Value": TABLE_NAME}},
            {"Parameter": {"Value": f"{TABLE_NAME}-redeployed"}},
        ]
        mock_get_client.return_value = ssm

        assert rr.resolve_adoptions_table() == TABLE_NAME
        rr.clear_cache()
        assert rr.resolve_adoptions_table() == f"{TABLE_NAME}-redeployed"
