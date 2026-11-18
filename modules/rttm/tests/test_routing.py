"""Routing of exported records (function-app/routing.py). No network call is made.

Record shapes follow Microsoft's documentation:
  Entra sign-in and audit logs streamed to an event hub (category + properties)
    https://learn.microsoft.com/entra/identity/monitoring-health/howto-stream-logs-to-event-hub
  Application Gateway WAF log (ApplicationGatewayFirewallLog, clientIp, action "Blocked")
    https://learn.microsoft.com/azure/web-application-firewall/ag/web-application-firewall-logs
  Front Door WAF log (clientIP, action "Block"; both category spellings)
    https://learn.microsoft.com/azure/web-application-firewall/afds/waf-front-door-monitor
  Defender for Cloud alert (alerts API schema)
    https://learn.microsoft.com/azure/defender-for-cloud/alerts-schemas

Run:  python3 -m unittest discover -s modules/rttm/tests -v
"""

import copy
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "function-app"))

import routing  # noqa: E402

TENANT = "aaaa0000-0000-4000-8000-00000000aaaa"
SUB = "bbbb0000-0000-4000-8000-00000000bbbb"
RECORDS_QUEUE_ONLY = None  # no cloud-event queue configured: the module default
CLOUD_QUEUE = "https://sqs.us-west-2.amazonaws.com/123456789012/cloud-event-queue"


def sign_in(category="SignInLogs"):
    return {
        "time": "2026-11-16T10:30:05.0000000Z",
        "resourceId": f"/tenants/{TENANT}/providers/Microsoft.aadiam",
        "operationName": "Sign-in activity",
        "category": category,
        "tenantId": TENANT,
        "resultType": "0",
        "callerIpAddress": "203.0.113.7",
        "correlationId": "d79f5bee-5860-4832-928f-3133e22ae912",
        "properties": {
            "id": "66ea54eb-6301-4ee5-be62-ff5a759b0100",
            "createdDateTime": "2026-11-16T10:30:00Z",
            "userPrincipalName": "testaccount1@contoso.com",
            "ipAddress": "203.0.113.7",
            "status": {"errorCode": 0},
            "location": {"city": "Redmond", "countryOrRegion": "US"},
        },
    }


AUDIT = {
    "time": "2026-11-16T10:31:00.0000000Z",
    "resourceId": f"/tenants/{TENANT}/providers/Microsoft.aadiam",
    "operationName": "Add member to role",
    "category": "AuditLogs",
    "tenantId": TENANT,
    "properties": {"id": "Directory_abc_1", "activityDisplayName": "Add member to role", "result": "success"},
}

ACTIVITY = {
    "time": "2026-11-16T10:31:30.0000000Z",
    "resourceId": f"/SUBSCRIPTIONS/{SUB}/RESOURCEGROUPS/APP/PROVIDERS/MICROSOFT.NETWORK/NETWORKSECURITYGROUPS/NSG1",
    "operationName": "MICROSOFT.NETWORK/NETWORKSECURITYGROUPS/SECURITYRULES/WRITE",
    "category": "Administrative",
    "resultType": "Success",
    "tenantId": TENANT,
}

# Defender alert as the Activity Log's Security category carries it (already exported today).
ACTIVITY_SECURITY = {
    "time": "2026-11-16T10:31:40.0000000Z",
    "resourceId": f"/subscriptions/{SUB}/resourceGroups/APP/providers/Microsoft.Security/locations/centralus/alerts/2518",
    "operationName": "Microsoft.Security/locations/alerts/activate/action",
    "category": "Security",
    "properties": {"severity": "Low", "compromisedEntity": "vm1"},
}

KEY_VAULT = {
    "time": "2026-11-16T10:31:50.0000000Z",
    "resourceId": f"/SUBSCRIPTIONS/{SUB}/RESOURCEGROUPS/APP/PROVIDERS/MICROSOFT.KEYVAULT/VAULTS/KV1",
    "operationName": "SecretGet",
    "category": "AuditEvent",
}

APP_GATEWAY_WAF = {
    "resourceId": f"/SUBSCRIPTIONS/{SUB}/RESOURCEGROUPS/EDGE/PROVIDERS/MICROSOFT.NETWORK/APPLICATIONGATEWAYS/GW1",
    "operationName": "ApplicationGatewayFirewall",
    "time": "2026-11-16T10:32:00.0000000Z",
    "category": "ApplicationGatewayFirewallLog",
    "properties": {
        "instanceId": "appgw_0",
        "clientIp": "198.51.100.9",
        "requestUri": "/?id=1%20or%201=1",
        "ruleId": "942100",
        "action": "Blocked",
        "hostname": "shop.example.com",
    },
}


def front_door_waf(category="FrontDoorWebApplicationFirewallLog"):
    return {
        "time": "2026-11-16T10:33:00.0000000Z",
        "resourceId": f"/SUBSCRIPTIONS/{SUB}/RESOURCEGROUPS/EDGE/PROVIDERS/MICROSOFT.CDN/PROFILES/FD1",
        "category": category,
        "operationName": "Microsoft.Cdn/Profiles/Write",
        "properties": {
            "clientIP": "198.51.100.10",
            "requestUri": "https://shop.example.com:443/?q=%27%20or%201=1",
            "ruleName": "Microsoft_DefaultRuleSet-1.1-SQLI-942100",
            "policy": "ShopPolicy",
            "action": "Block",
            "host": "shop.example.com",
        },
    }


# Continuous export, alerts API shape (id / name / type / properties).
DEFENDER_API = {
    "id": f"/subscriptions/{SUB}/resourceGroups/APP/providers/Microsoft.Security/locations/westeurope/alerts/2518298467986649999_4d25bfef",
    "name": "2518298467986649999_4d25bfef",
    "type": "Microsoft.Security/Locations/alerts",
    "properties": {
        "systemAlertId": "2518298467986649999_4d25bfef",
        "alertType": "VM_SuspiciousScreenSaver",
        "alertDisplayName": "Suspicious Screensaver process executed",
        "severity": "Medium",
        "compromisedEntity": "vm1",
    },
}

# Flat shape (top-level AlertType / SystemAlertId), also recognised.
DEFENDER_FLAT = {
    "VendorName": "Microsoft",
    "AlertType": "SIMULATED_SQL.VM_BruteForce",
    "SystemAlertId": "2342409243234234_F2BFED55",
    "AlertDisplayName": "Suspected brute force attack",
    "Severity": "High",
}


class KindOfRecord(unittest.TestCase):
    def test_every_exported_category_gets_its_kind(self):
        cases = [
            (sign_in("SignInLogs"), "azure.signin"),
            (sign_in("NonInteractiveUserSignInLogs"), "azure.signin"),
            (sign_in("ServicePrincipalSignInLogs"), "azure.signin"),
            (sign_in("ManagedIdentitySignInLogs"), "azure.signin"),
            (AUDIT, "azure.audit"),
            (ACTIVITY, "azure.activity"),
            (ACTIVITY_SECURITY, "azure.activity"),
            ({"category": "Policy"}, "azure.activity"),
            ({"category": "Alert"}, "azure.activity"),
            (KEY_VAULT, "azure.keyvault"),
            (APP_GATEWAY_WAF, "azure.waf"),
            (front_door_waf("FrontDoorWebApplicationFirewallLog"), "azure.waf"),
            (front_door_waf("FrontdoorWebApplicationFirewallLog"), "azure.waf"),  # classic spelling
            (DEFENDER_API, "azure.defender"),
            (DEFENDER_FLAT, "azure.defender"),
            ({"category": "SecurityAlerts"}, "azure.defender"),
        ]
        for record, kind in cases:
            with self.subTest(category=record.get("category"), kind=kind):
                self.assertEqual(routing.kind_of_record(record), kind)

    def test_categories_without_a_reader_have_no_kind(self):
        for category in ("ADFSSignInLogs", "MicrosoftServicePrincipalSignInLogs", "RiskyUsers", "UserRiskEvents"):
            with self.subTest(category=category):
                self.assertIsNone(routing.kind_of_record(sign_in(category)))
        self.assertIsNone(routing.kind_of_record({"category": "AuditEvent", "resourceId": "/x/providers/Microsoft.Sql/servers/s"}))
        self.assertIsNone(routing.kind_of_record("not a record"))
        self.assertIsNone(routing.kind_of_record(None))

    def test_properties_sent_as_a_json_string_are_read(self):
        record = {"type": "other", "properties": json.dumps({"alertType": "X", "systemAlertId": "1"})}
        self.assertEqual(routing.kind_of_record(record), "azure.defender")
        self.assertEqual(routing.properties_of({"properties": "not json"}), {})


class DefaultsKeepTheExistingBehaviour(unittest.TestCase):
    """No cloud-event queue configured = what the module did before these options existed."""

    def test_envelope_is_forwarded_byte_for_byte(self):
        event = {
            "records": [
                sign_in(), sign_in("NonInteractiveUserSignInLogs"), sign_in("ADFSSignInLogs"),
                sign_in("RiskyUsers"), AUDIT, ACTIVITY, ACTIVITY_SECURITY, KEY_VAULT,
            ]
        }
        before = copy.deepcopy(event)
        routed = routing.route_message(event, RECORDS_QUEUE_ONLY)
        # json.dumps(event_data) is exactly what the function sent before routing existed.
        self.assertEqual(routed.record_bodies, [json.dumps(before)])
        self.assertEqual(routed.cloud_event_bodies, [])
        self.assertEqual(sum(routed.unread.values()), 0)
        self.assertEqual(event, before)  # nothing mutated, nothing lifted

    def test_non_envelope_messages_are_forwarded_unchanged(self):
        for event in ({"records": []}, {"hello": "world"}, [ACTIVITY, AUDIT], {"records": "odd"}):
            with self.subTest(event=str(event)[:30]):
                routed = routing.route_message(event, RECORDS_QUEUE_ONLY)
                self.assertEqual(routed.record_bodies, [json.dumps(event)])

    def test_sign_in_properties_are_not_lifted(self):
        routed = routing.route_message({"records": [sign_in()]}, RECORDS_QUEUE_ONLY)
        record = json.loads(routed.record_bodies[0])["records"][0]
        self.assertNotIn("userPrincipalName", record)
        self.assertEqual(record["properties"]["userPrincipalName"], "testaccount1@contoso.com")

    def test_kinds_setting_is_ignored_without_the_queue(self):
        routed = routing.route_message({"records": [sign_in()]}, "", kinds="azure.signin")
        self.assertEqual(len(routed.record_bodies), 1)
        self.assertEqual(routed.cloud_event_bodies, [])


class WafAndDefenderWithoutTheCloudEventQueue(unittest.TestCase):
    def test_counted_and_never_sent_to_the_records_queue(self):
        event = {"records": [ACTIVITY, APP_GATEWAY_WAF, front_door_waf(), DEFENDER_API, AUDIT]}
        routed = routing.route_message(event, RECORDS_QUEUE_ONLY)
        self.assertEqual(dict(routed.unread), {"azure.waf": 2, "azure.defender": 1})
        self.assertEqual(routed.cloud_event_bodies, [])
        self.assertEqual(len(routed.record_bodies), 1)
        self.assertEqual(json.loads(routed.record_bodies[0]), {"records": [ACTIVITY, AUDIT]})

    def test_nothing_is_sent_when_every_record_is_unread(self):
        routed = routing.route_message({"records": [APP_GATEWAY_WAF]}, RECORDS_QUEUE_ONLY)
        self.assertEqual(routed.record_bodies, [])
        self.assertEqual(routed.cloud_event_bodies, [])
        self.assertEqual(dict(routed.unread), {"azure.waf": 1})

    def test_bare_defender_alert_message(self):
        # Continuous export does not use the {"records": [...]} envelope.
        routed = routing.route_message(DEFENDER_API, RECORDS_QUEUE_ONLY)
        self.assertEqual(routed.record_bodies, [])
        self.assertEqual(dict(routed.unread), {"azure.defender": 1})


class WithTheCloudEventQueue(unittest.TestCase):
    def test_waf_and_defender_go_to_the_cloud_event_queue_one_per_message(self):
        event = {"records": [ACTIVITY, APP_GATEWAY_WAF, sign_in(), front_door_waf("FrontdoorWebApplicationFirewallLog"), DEFENDER_API]}
        routed = routing.route_message(event, CLOUD_QUEUE, tenant_id=TENANT)
        self.assertEqual(sum(routed.unread.values()), 0)
        self.assertEqual(json.loads(routed.record_bodies[0]), {"records": [ACTIVITY, sign_in()]})
        messages = [json.loads(body) for body in routed.cloud_event_bodies]
        self.assertEqual([m["rawKind"] for m in messages], ["azure.waf", "azure.waf", "azure.defender"])
        for message in messages:
            self.assertEqual(set(message), {"provider", "rawKind", "providerAccountId", "raw"})
            self.assertEqual(message["provider"], "azure")
            # WAF and Defender records carry no tenant id: the configured one is supplied.
            self.assertEqual(message["providerAccountId"], TENANT)
        # Records are passed as Azure emitted them.
        self.assertEqual(messages[0]["raw"], APP_GATEWAY_WAF)
        self.assertEqual(messages[2]["raw"], DEFENDER_API)

    def test_bare_defender_alert_and_list_of_alerts(self):
        routed = routing.route_message(DEFENDER_FLAT, CLOUD_QUEUE, tenant_id=TENANT)
        self.assertEqual(routed.record_bodies, [])
        self.assertEqual(json.loads(routed.cloud_event_bodies[0])["raw"], DEFENDER_FLAT)
        routed = routing.route_message([DEFENDER_API, DEFENDER_FLAT], CLOUD_QUEUE, tenant_id=TENANT)
        self.assertEqual(len(routed.cloud_event_bodies), 2)

    def test_a_tenant_id_on_the_record_wins_over_the_configured_one(self):
        record = dict(APP_GATEWAY_WAF, tenantId="cccc0000-0000-4000-8000-00000000cccc")
        message = json.loads(routing.to_cloud_event(record, "azure.waf", TENANT))
        self.assertEqual(message["providerAccountId"], "cccc0000-0000-4000-8000-00000000cccc")
        nested = dict(DEFENDER_API, properties=dict(DEFENDER_API["properties"], tenantId="dddd"))
        self.assertEqual(json.loads(routing.to_cloud_event(nested, "azure.defender", TENANT))["providerAccountId"], "dddd")

    def test_no_account_id_when_none_is_known(self):
        message = json.loads(routing.to_cloud_event(APP_GATEWAY_WAF, "azure.waf", None))
        self.assertNotIn("providerAccountId", message)

    def test_identity_kinds_move_only_when_listed_and_stay_unshaped(self):
        event = {"records": [sign_in("ServicePrincipalSignInLogs"), AUDIT, ACTIVITY]}
        routed = routing.route_message(event, CLOUD_QUEUE, kinds=" azure.signin , Azure.Audit ", tenant_id="other")
        self.assertEqual(json.loads(routed.record_bodies[0]), {"records": [ACTIVITY]})
        messages = [json.loads(body) for body in routed.cloud_event_bodies]
        self.assertEqual([m["rawKind"] for m in messages], ["azure.signin", "azure.audit"])
        self.assertEqual(messages[0]["raw"], sign_in("ServicePrincipalSignInLogs"))  # not lifted
        self.assertEqual(messages[0]["providerAccountId"], TENANT)  # the record's own tenant id
        # WAF is no longer listed, so it has no queue: left out, not sent to the records queue.
        routed = routing.route_message({"records": [APP_GATEWAY_WAF]}, CLOUD_QUEUE, kinds="azure.signin")
        self.assertEqual((routed.record_bodies, routed.cloud_event_bodies), ([], []))
        self.assertEqual(dict(routed.unread), {"azure.waf": 1})

    def test_kinds_are_counted(self):
        routed = routing.route_message({"records": [ACTIVITY, AUDIT, APP_GATEWAY_WAF, {"category": "Other"}]}, CLOUD_QUEUE)
        self.assertEqual(dict(routed.kinds), {"azure.activity": 1, "azure.audit": 1, "azure.waf": 1, "unknown": 1})


class OversizedBatches(unittest.TestCase):
    def test_a_batch_over_the_sqs_limit_is_split_and_loses_nothing(self):
        big = dict(ACTIVITY, padding="x" * 100_000)
        event = {"records": [dict(big, n=i) for i in range(6)]}
        routed = routing.route_message(event, RECORDS_QUEUE_ONLY)
        self.assertGreater(len(routed.record_bodies), 1)
        for body in routed.record_bodies:
            self.assertLessEqual(len(body.encode("utf-8")), 262_144)
        forwarded = [r for body in routed.record_bodies for r in json.loads(body)["records"]]
        self.assertEqual(forwarded, event["records"])

    def test_a_single_oversized_record_is_still_sent_as_is(self):
        event = {"records": [dict(ACTIVITY, padding="x" * 300_000)]}
        routed = routing.route_message(event, RECORDS_QUEUE_ONLY)
        self.assertEqual(routed.record_bodies, [json.dumps(event)])


if __name__ == "__main__":
    unittest.main()
