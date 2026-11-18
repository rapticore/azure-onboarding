import json
import logging
import boto3
import os
import jwt
import requests
from botocore.exceptions import ClientError, NoCredentialsError, ProfileNotFound
from botocore.config import Config
from pathlib import Path

logger = logging.getLogger(__name__)

def create_sso_session(profile_name: str = None, region: str = None) -> boto3.Session:
    region = region or os.getenv("AWS_REGION", "us-east-1")
    profile = profile_name or os.getenv("AWS_PROFILE", "default")

    token_file = os.getenv("AWS_WEB_IDENTITY_TOKEN_FILE")
    role_arn = os.getenv("AWS_ROLE_ARN")
    logger.info(f"Creating AWS session with profile: {profile}, region: {region}, token_file: {token_file}, role_arn: {role_arn}, identity endpoint: {os.getenv('IDENTITY_ENDPOINT')}")

    try:
        # Detect Azure Managed Identity environment (IDENTITY_ENDPOINT exists in Azure Functions)
        if os.getenv("IDENTITY_ENDPOINT"):
            logger.info("Detected Azure Managed Identity environment, preparing AWS OIDC variables...")

            # Get required config
            audience = os.getenv("AWS_OIDC_AUDIENCE")  # You set this in Azure Function config
            role_arn = os.getenv("AWS_ROLE_ARN")
            msi_client_id = os.getenv("MSI_CLIENT_ID")  # optional, for user-assigned identity

            if not audience or not role_arn:
                raise RuntimeError("AWS_OIDC_AUDIENCE and AWS_ROLE_ARN must be set in Azure Function configuration.")

            # Call Azure MSI endpoint to get OIDC token
            identity_endpoint = os.environ["IDENTITY_ENDPOINT"]
            identity_header = os.environ["IDENTITY_HEADER"]

            params = {
                "api-version": "2019-08-01",
                "resource": audience,
                "client_id": msi_client_id
            }

            headers = {"X-IDENTITY-HEADER": identity_header}

            logger.info("Fetching OIDC token from Azure MSI...")
            logger.info(f"Calling MSI endpoint: {identity_endpoint}, params={params}")
            resp = requests.get(identity_endpoint, params=params, headers=headers)
            # Never log the response body: it holds the managed identity's access token, which anyone who can read
            # this Function's logs could use to assume the forwarding role until it expires.
            logger.info(f"MSI response status: {resp.status_code}")
            resp.raise_for_status()

            token = resp.json().get("access_token")
            if not token:
                raise RuntimeError("No access_token returned by Azure MSI endpoint.")

            # Save token to temp file
            token_file_path = "/tmp/aws_web_identity_token"
            Path(token_file_path).write_text(token)

            # Set AWS vars for boto3
            os.environ["AWS_WEB_IDENTITY_TOKEN_FILE"] = token_file_path
            os.environ["AWS_ROLE_ARN"] = role_arn

            logger.info("AWS_WEB_IDENTITY_TOKEN_FILE and AWS_ROLE_ARN set for AWS STS.")

            token_file = token_file_path  # update for downstream logic

        # Now try AWS session creation
        use_oidc = token_file and role_arn
        if use_oidc:
            logger.info("Using OIDC Web Identity credentials for AWS...")

            with open(token_file, "r") as f:
                web_identity_token = f.read()

            # The token's audience and subject only, to diagnose a trust mismatch; never the token or all its claims.
            claims = jwt.decode(web_identity_token, options={"verify_signature": False})
            logger.info(f"OIDC token audience={claims.get('aud')} subject={claims.get('sub')}")

            try:
                sts_client = boto3.client("sts", region_name=region)
                assumed_role = sts_client.assume_role_with_web_identity(
                    RoleArn=role_arn,
                    RoleSessionName="azure-function-session",
                    WebIdentityToken=web_identity_token
                )
                logger.info("Got credentials from AWS STS")
            except Exception as e:
                import traceback
                logger.error("STS call failed")
                logger.error(traceback.format_exc())
                raise

            logger.info("Got credentials from AWS STS assume_role_with_web_identity")
            
            creds = assumed_role["Credentials"]
            session = boto3.Session(
                aws_access_key_id=creds["AccessKeyId"],
                aws_secret_access_key=creds["SecretAccessKey"],
                aws_session_token=creds["SessionToken"],
                region_name=region
            )

            # identity = session.client("sts").get_caller_identity()
            logger.info(f"Assumed role in AWS")
            return session

        # Local/default credentials
        logger.info("Using default AWS credential chain.")
        session = boto3.Session(profile_name=profile, region_name=region)
        identity = session.client("sts").get_caller_identity()
        logger.info(f"Authenticated as: {identity.get('Arn', 'Unknown')}")
        return session

    except ProfileNotFound as e:
        logger.exception(f"AWS profile '{profile}' not found: {e}")
        raise ValueError(f"AWS profile '{profile}' not found. Please run: aws configure sso --profile {profile}")
    except NoCredentialsError as e:
        logger.exception(f"No credentials available: {e}")
        raise ValueError(f"No AWS credentials found. If local, please run: aws sso login --profile {profile}")
    except ClientError as e:
        error_code = e.response['Error']['Code']
        if error_code == 'TokenRefreshRequired':
            raise ValueError(f"AWS SSO token expired for profile '{profile}'. Run: aws sso login --profile {profile}")
        elif error_code == 'UnauthorizedOperation':
            raise ValueError(f"Profile '{profile}' lacks required permissions.")
        else:
            raise ValueError(f"AWS ClientError: {error_code}")
    except Exception as e:
        logger.exception("Unexpected error during AWS session creation")
        raise RuntimeError(f"AWS session initialization failed: {str(e)}")

def handle_signin_log(event_str: str):

    try:
        # The queue's Region, from AWS_REGION (the module sets it from var.aws_region). It was hard-coded to
        # us-west-2 below, so a queue in another Region could not be reached whatever the variable said.
        region = os.getenv("AWS_REGION", "us-west-2")
        session = create_sso_session(region=region)

        # # Configure boto3 client with retries and timeouts
        config = Config(
            region_name=region,
            retries={'max_attempts': 3, 'mode': 'adaptive'},
            max_pool_connections=50
        )

        # Create SQS client from session
        sqs_client = session.client('sqs', config=config)


        event_data = json.loads(event_str)

        # Optionally validate, enrich, or log
        # Not the event itself: sign-in and audit records are the customer's personal data and do not belong in
        # Function logs.
        logger.info("Forwarding event batch")

        # Send to SQS
        QUEUE_URL = os.getenv("AWS_SQS_QUEUE_URL")  # required
        response = sqs_client.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(event_data)
        )
        logger.info(f"SQS MessageId: {response.get("MessageId")}")

    except Exception as e:
        logger.exception(f"Error processing event: {str(e)}")
        raise
