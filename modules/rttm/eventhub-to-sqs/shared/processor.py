import json
import logging
import boto3
import os
from botocore.exceptions import ClientError, NoCredentialsError, ProfileNotFound
from botocore.config import Config


logger = logging.getLogger(__name__)

QUEUE_URL = os.getenv("AWS_SQS_QUEUE_URL")  # required

def create_sso_session(profile_name: str = None, region: str = None) -> boto3.Session:

    region = region or os.getenv("AWS_REGION", "us-east-1")
    profile = profile_name or os.getenv("AWS_PROFILE", "default")

    # Check if we’re in an Azure environment using OIDC
    use_oidc = (
        os.getenv("AWS_WEB_IDENTITY_TOKEN_FILE") and
        os.getenv("AWS_ROLE_ARN")
    )

    try:
        if use_oidc:
            # OIDC Web Identity in Azure
            logger.info("Using OIDC Web Identity credentials for Azure environment")
            session = boto3.Session(region_name=region)
            sts = session.client("sts")
            identity = sts.get_caller_identity()
            logger.info(f"Assumed role in Azure as: {identity.get('Arn', 'Unknown')}")
            return session

        # Try default credentials (e.g., ~/.aws/credentials or env vars)
        logger.info("Attempting to use default AWS credential chain")
        session = boto3.Session(profile_name=profile, region_name=region)
        sts = session.client("sts")
        identity = sts.get_caller_identity()
        logger.info(f"Authenticated as: {identity.get('Arn', 'Unknown')}")
        return session

    except ProfileNotFound as e:
        logger.error(f"AWS profile '{profile}' not found: {e}")
        raise ValueError(
            f"AWS profile '{profile}' not found. Please ensure your AWS config is set up correctly.\n"
            f"Run: aws configure sso --profile {profile}"
        )
    except NoCredentialsError as e:
        logger.error(f"No credentials available: {e}")
        raise ValueError(
            f"No AWS credentials found. If local, please run: aws sso login --profile {profile}"
        )
    except ClientError as e:
        error_code = e.response['Error']['Code']
        if error_code == 'TokenRefreshRequired':
            raise ValueError(
                f"AWS SSO token has expired for profile '{profile}'.\n"
                f"Run: aws sso login --profile {profile}"
            )
        elif error_code == 'UnauthorizedOperation':
            raise ValueError(
                f"Profile '{profile}' lacks required permissions."
            )
        else:
            raise ValueError(f"AWS ClientError: {error_code}")
    except Exception as e:
        logger.exception("Unexpected error during AWS session creation")
        raise RuntimeError(f"AWS session initialization failed: {str(e)}")


def handle_signin_log(event_str: str):

    try:
        session = create_sso_session('dev1', 'us-west-2')

        # # Configure boto3 client with retries and timeouts
        config = Config(
            region_name='us-west-2',
            retries={'max_attempts': 3, 'mode': 'adaptive'},
            max_pool_connections=50
        )

        # Create SQS client from session
        sqs_client = session.client('sqs', config=config)


        event_data = json.loads(event_str)

        # Optionally validate, enrich, or log
        print("Forwarding event:", event_data)

        # Send to SQS
        response = sqs_client.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(event_data)
        )
        print("SQS MessageId:", response.get("MessageId"))

    except Exception as e:
        print("Error processing event:", str(e))
        raise
