"""Routing of exported Azure records to the Rapticore queue that reads them.

Every record gets a kind from its own `category` (Azure Monitor batches can mix
categories, so the kind is decided per record, never per batch):

    azure.signin    Entra sign-in logs (interactive, non-interactive, service
                    principal, managed identity)
    azure.audit     Entra directory audit logs
    azure.activity  subscription Activity Log
    azure.keyvault  Key Vault data-plane audit
    azure.waf       Application Gateway / Front Door WAF logs
    azure.defender  Defender for Cloud alerts (continuous export)

Two destinations:

  * the records queue (AWS_SQS_QUEUE_URL) -- receives the `{"records": [...]}`
    envelope exactly as Azure Monitor emitted it. Records are never reshaped.
  * the cloud-event queue (AWS_CLOUD_EVENT_SQS_QUEUE_URL, optional) -- receives
    one message per record:
        {"provider": "azure", "rawKind": <kind>, "providerAccountId": <tenant id>, "raw": <record>}

WAF and Defender records are read only from the cloud-event queue. When that
queue is not configured they are counted and left out; they are never sent to
the records queue, which has no reader for them.

This module has no third-party imports so it can be tested without the Azure
Functions or AWS packages.

Category names, from Microsoft's documentation:
  Entra diagnostic setting: SignInLogs, NonInteractiveUserSignInLogs,
    ServicePrincipalSignInLogs, ManagedIdentitySignInLogs, AuditLogs
    https://learn.microsoft.com/entra/identity/monitoring-health/concept-diagnostic-settings-logs-options
  Application Gateway WAF: ApplicationGatewayFirewallLog
    https://learn.microsoft.com/azure/web-application-firewall/ag/web-application-firewall-logs
  Front Door WAF: FrontDoorWebApplicationFirewallLog (Standard/Premium) and
    FrontdoorWebApplicationFirewallLog (classic); Microsoft's own sample record
    for Standard/Premium carries the classic spelling, so categories are
    compared without case.
    https://learn.microsoft.com/azure/web-application-firewall/afds/waf-front-door-monitor
  Defender for Cloud continuous export: alerts arrive "using the same schema as
    the alerts API" and carry no `category`.
    https://learn.microsoft.com/azure/defender-for-cloud/alerts-schemas
"""

import json
import re
from collections import Counter
from dataclasses import dataclass, field

# SQS rejects a message body over 262,144 bytes; leave headroom.
MAX_SQS_BODY_BYTES = 250 * 1024

KIND_SIGNIN = "azure.signin"
KIND_AUDIT = "azure.audit"
KIND_ACTIVITY = "azure.activity"
KIND_KEYVAULT = "azure.keyvault"
KIND_WAF = "azure.waf"
KIND_DEFENDER = "azure.defender"

# Lower-cased category -> kind. A category that is not listed here (for example
# ADFSSignInLogs, MicrosoftServicePrincipalSignInLogs, RiskyUsers,
# UserRiskEvents) has no kind: the record stays on the records queue, as before.
KIND_BY_CATEGORY = {
    "signinlogs": KIND_SIGNIN,
    "noninteractiveusersigninlogs": KIND_SIGNIN,
    "serviceprincipalsigninlogs": KIND_SIGNIN,
    "managedidentitysigninlogs": KIND_SIGNIN,
    "auditlogs": KIND_AUDIT,
    "applicationgatewayfirewalllog": KIND_WAF,
    "frontdoorwebapplicationfirewalllog": KIND_WAF,
    "securityalerts": KIND_DEFENDER,
    # Subscription Activity Log categories.
    "administrative": KIND_ACTIVITY,
    "security": KIND_ACTIVITY,
    "policy": KIND_ACTIVITY,
    "servicehealth": KIND_ACTIVITY,
    "alert": KIND_ACTIVITY,
    "recommendation": KIND_ACTIVITY,
    "autoscale": KIND_ACTIVITY,
    "resourcehealth": KIND_ACTIVITY,
}

# Kinds the records queue has no reader for.
CLOUD_EVENT_ONLY_KINDS = frozenset({KIND_WAF, KIND_DEFENDER})
DEFAULT_CLOUD_EVENT_KINDS = "azure.waf,azure.defender"

_KEYVAULT_RESOURCE = re.compile(r"/providers/microsoft\.keyvault/vaults/", re.IGNORECASE)
_DEFENDER_ALERT_TYPE = re.compile(r"^microsoft\.security/locations/alerts$", re.IGNORECASE)


def properties_of(record):
    """The record's `properties` as a dict (Azure sometimes sends it as a JSON string)."""
    properties = record.get("properties") if isinstance(record, dict) else None
    if isinstance(properties, dict):
        return properties
    if isinstance(properties, str):
        try:
            parsed = json.loads(properties)
        except ValueError:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def kind_of_record(record):
    """The kind of one exported record, or None when it is none we know."""
    if not isinstance(record, dict):
        return None
    category = record.get("category")
    category = category.lower() if isinstance(category, str) else ""
    if category == "auditevent" and _KEYVAULT_RESOURCE.search(str(record.get("resourceId") or "")):
        return KIND_KEYVAULT
    if category in KIND_BY_CATEGORY:
        return KIND_BY_CATEGORY[category]
    properties = properties_of(record)
    if (
        record.get("AlertType")
        or record.get("SystemAlertId")
        or properties.get("alertType")
        or properties.get("systemAlertId")
        or _DEFENDER_ALERT_TYPE.match(str(record.get("type") or ""))
    ):
        return KIND_DEFENDER
    return None


def cloud_event_kinds(cloud_event_queue_url, kinds=None):
    """Kinds sent to the cloud-event queue. Empty when that queue is not configured."""
    if not cloud_event_queue_url:
        return frozenset()
    return frozenset(
        kind.strip().lower()
        for kind in (kinds or DEFAULT_CLOUD_EVENT_KINDS).split(",")
        if kind.strip()
    )


def records_of_message(event_data):
    """The records of one Event Hub message: `{"records": [...]}`, a bare list, or one record."""
    if isinstance(event_data, list):
        return event_data
    if isinstance(event_data, dict) and isinstance(event_data.get("records"), list):
        return event_data["records"]
    return [event_data]


def to_cloud_event(record, kind, tenant_id=None):
    """The cloud-event queue message of one record. The record itself is not changed."""
    account = record.get("tenantId") or properties_of(record).get("tenantId") or tenant_id
    message = {"provider": "azure", "rawKind": kind}
    if account:
        message["providerAccountId"] = str(account)
    message["raw"] = record
    return json.dumps(message)


def to_record_batches(records, max_bytes=MAX_SQS_BODY_BYTES):
    """`{"records": [...]}` message bodies, split so each stays under the SQS limit."""
    batches = []
    current = []
    current_bytes = 20  # envelope overhead
    for record in records:
        record_bytes = len(json.dumps(record)) + 2
        if current and current_bytes + record_bytes > max_bytes:
            batches.append(current)
            current = []
            current_bytes = 20
        current.append(record)
        current_bytes += record_bytes
    if current:
        batches.append(current)
    return [json.dumps({"records": batch}) for batch in batches]


@dataclass
class RoutedMessage:
    """What to send for one Event Hub message."""

    record_bodies: list = field(default_factory=list)  # -> records queue
    cloud_event_bodies: list = field(default_factory=list)  # -> cloud-event queue
    unread: Counter = field(default_factory=Counter)  # kind -> records left out
    kinds: Counter = field(default_factory=Counter)  # kind -> records seen


def route_message(event_data, cloud_event_queue_url=None, kinds=None, tenant_id=None,
                  max_bytes=MAX_SQS_BODY_BYTES):
    """Split one Event Hub message by destination.

    When no record is diverted and the message fits in one SQS message, the
    body for the records queue is the message itself, unchanged -- the same
    bytes this function has always sent.
    """
    to_cloud_event_queue = cloud_event_kinds(cloud_event_queue_url, kinds)
    routed = RoutedMessage()
    kept = []
    diverted = False
    for record in records_of_message(event_data):
        kind = kind_of_record(record)
        routed.kinds[kind or "unknown"] += 1
        if kind and kind in to_cloud_event_queue:
            routed.cloud_event_bodies.append(to_cloud_event(record, kind, tenant_id))
            diverted = True
        elif kind in CLOUD_EVENT_ONLY_KINDS:
            routed.unread[kind] += 1
            diverted = True
        else:
            kept.append(record)

    if not diverted:
        body = json.dumps(event_data)
        if len(body) <= max_bytes or len(kept) < 2:
            routed.record_bodies = [body]
            return routed
    routed.record_bodies = to_record_batches(kept, max_bytes)
    return routed
