"""AWS client factory with STS assume-role for cross-account access."""

import boto3
from botocore.config import Config

from .config import BE_READ_ROLE_ARN, REGION

_boto_config = Config(
    region_name=REGION,
    retries={"max_attempts": 3, "mode": "adaptive"},
)


def get_be_session() -> boto3.Session:
    """Get a boto3 session using the BE domain read role via STS assume-role."""
    sts = boto3.client("sts", config=_boto_config)
    creds = sts.assume_role(
        RoleArn=BE_READ_ROLE_ARN,
        RoleSessionName="diagnostics-mcp",
        DurationSeconds=900,
    )["Credentials"]
    return boto3.Session(
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        region_name=REGION,
    )


def get_client(service_name: str):
    """Get a boto3 client for the given service in the BE account."""
    session = get_be_session()
    return session.client(service_name, config=_boto_config)
