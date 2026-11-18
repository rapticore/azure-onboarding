"""processor.handle_signin_log sends each body to the right queue.

boto3 / botocore / jwt / requests are replaced by stand-ins, and the AWS session
is a fake: no credentials are read and no network call is made.
"""

import json
import os
import sys
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "function-app"))

# Stand-ins only when the real packages are not installed.
for name in ("boto3", "jwt", "requests"):
    try:
        __import__(name)
    except ImportError:
        sys.modules[name] = mock.MagicMock(name=name)
try:
    import botocore.config  # noqa: F401
    import botocore.exceptions  # noqa: F401
except ImportError:
    exceptions = types.ModuleType("botocore.exceptions")
    for error in ("ClientError", "NoCredentialsError", "ProfileNotFound"):
        setattr(exceptions, error, type(error, (Exception,), {}))
    config = types.ModuleType("botocore.config")
    config.Config = lambda **kwargs: kwargs
    sys.modules.update({"botocore": types.ModuleType("botocore"), "botocore.exceptions": exceptions, "botocore.config": config})

import processor  # noqa: E402

RECORDS_QUEUE = "https://sqs.us-west-2.amazonaws.com/123456789012/records-queue"
CLOUD_QUEUE = "https://sqs.us-west-2.amazonaws.com/123456789012/cloud-event-queue"
TENANT = "aaaa0000-0000-4000-8000-00000000aaaa"

ACTIVITY = {"category": "Administrative", "operationName": "MICROSOFT.NETWORK/NETWORKSECURITYGROUPS/WRITE"}
WAF = {"category": "ApplicationGatewayFirewallLog", "properties": {"clientIp": "198.51.100.9", "action": "Blocked"}}
DEFENDER = {"type": "Microsoft.Security/Locations/alerts", "properties": {"alertType": "X", "systemAlertId": "1"}}


class FakeSqs:
    def __init__(self):
        self.sent = []

    def send_message(self, QueueUrl, MessageBody):
        self.sent.append((QueueUrl, MessageBody))
        return {"MessageId": str(len(self.sent))}


class HandleSignInLog(unittest.TestCase):
    def run_handler(self, event, env):
        sqs = FakeSqs()
        session = mock.Mock()
        session.client.return_value = sqs
        base = {"AWS_SQS_QUEUE_URL": RECORDS_QUEUE, "AWS_REGION": "us-west-2"}
        with mock.patch.dict(os.environ, {**base, **env}, clear=True), \
                mock.patch.object(processor, "create_sso_session", return_value=session) as create:
            processor.handle_signin_log(json.dumps(event))
        return sqs.sent, create

    def test_default_settings_send_the_unchanged_event_to_the_records_queue(self):
        event = {"records": [ACTIVITY, {"category": "SignInLogs", "properties": {"userPrincipalName": "a@b.c"}}]}
        sent, _ = self.run_handler(event, {})
        self.assertEqual(sent, [(RECORDS_QUEUE, json.dumps(event))])

    def test_waf_and_defender_without_the_cloud_event_queue_are_logged_not_sent(self):
        with self.assertLogs(processor.logger, level="WARNING") as logs:
            sent, _ = self.run_handler({"records": [ACTIVITY, WAF, DEFENDER]}, {})
        self.assertEqual(sent, [(RECORDS_QUEUE, json.dumps({"records": [ACTIVITY]}))])
        self.assertIn("2 record(s) not forwarded", logs.output[0])
        self.assertIn("AWS_CLOUD_EVENT_SQS_QUEUE_URL is not set", logs.output[0])

    def test_no_aws_session_is_opened_when_there_is_nothing_to_send(self):
        with self.assertLogs(processor.logger, level="WARNING"):
            sent, create = self.run_handler({"records": [WAF]}, {})
        self.assertEqual(sent, [])
        create.assert_not_called()

    def test_waf_and_defender_go_to_the_cloud_event_queue_with_the_tenant_id(self):
        env = {"AWS_CLOUD_EVENT_SQS_QUEUE_URL": CLOUD_QUEUE, "CLOUD_EVENT_KINDS": "azure.waf,azure.defender", "AZURE_TENANT_ID": TENANT}
        sent, _ = self.run_handler({"records": [ACTIVITY, WAF, DEFENDER]}, env)
        self.assertEqual(sent[0], (RECORDS_QUEUE, json.dumps({"records": [ACTIVITY]})))
        self.assertEqual([url for url, _ in sent[1:]], [CLOUD_QUEUE, CLOUD_QUEUE])
        self.assertEqual(
            [json.loads(body) for _, body in sent[1:]],
            [
                {"provider": "azure", "rawKind": "azure.waf", "providerAccountId": TENANT, "raw": WAF},
                {"provider": "azure", "rawKind": "azure.defender", "providerAccountId": TENANT, "raw": DEFENDER},
            ],
        )

    def test_a_send_failure_is_raised_so_the_invocation_fails(self):
        session = mock.Mock()
        session.client.return_value.send_message.side_effect = RuntimeError("AccessDenied")
        with mock.patch.dict(os.environ, {"AWS_SQS_QUEUE_URL": RECORDS_QUEUE}, clear=True), \
                mock.patch.object(processor, "create_sso_session", return_value=session), \
                self.assertLogs(processor.logger, level="ERROR"), \
                self.assertRaises(RuntimeError):
            processor.handle_signin_log(json.dumps({"records": [ACTIVITY]}))


if __name__ == "__main__":
    unittest.main()
