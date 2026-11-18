"""With every new variable at its default, the module adds no resource.

A static check of main.tf / variables.tf (no Terraform run, no Azure call):
every resource that is not in the pre-existing set must be switched by `count`
or `for_each`, and the variables that switch it must default to off / empty.
"""

import os
import re
import unittest

MODULE = os.path.join(os.path.dirname(__file__), "..")

# Resources the module created before the optional sources were added.
EXISTING = {
    "azurerm_storage_account.function_storage",
    "azurerm_log_analytics_workspace.law",
    "azurerm_application_insights.function_insights",
    "azurerm_service_plan.function_plan",
    "azurerm_linux_function_app.entra_processor",
    "azurerm_storage_container.function_code_container",
    "azurerm_storage_blob.function_code",
    "azurerm_eventhub_namespace.entra_diag",
    "azurerm_eventhub.entra_diag",
    "azurerm_eventhub_namespace_authorization_rule.entra_diag",
    "azurerm_eventhub_consumer_group.function_consumer",
    "azurerm_monitor_aad_diagnostic_setting.entra_diag_logs",
    "azurerm_monitor_diagnostic_setting.activity_log_nsg",
}

# New resource -> the expression that switches it.
SWITCHES = {
    "azurerm_monitor_diagnostic_setting.waf_logs": "for_each = local.waf_log_targets",
    "azurerm_eventhub_authorization_rule.defender_send": "count = var.enable_defender_alert_export ? 1 : 0",
    "azurerm_security_center_automation.defender_alerts": "count = var.enable_defender_alert_export ? 1 : 0",
}

OFF_BY_DEFAULT = {
    "waf_application_gateway_ids": "[]",
    "waf_front_door_profile_ids": "[]",
    "enable_defender_alert_export": "false",
    "aws_cloud_event_sqs_queue_url": '""',
}

ENTRA_DEFAULT = [
    "AuditLogs", "SignInLogs", "NonInteractiveUserSignInLogs", "ServicePrincipalSignInLogs",
    "ManagedIdentitySignInLogs", "ADFSSignInLogs", "MicrosoftServicePrincipalSignInLogs",
]


def read(name):
    with open(os.path.join(MODULE, name), encoding="utf-8") as handle:
        return handle.read()


def blocks(text, keyword):
    """{address: body} of every top-level `keyword "a" ["b"] { ... }` block."""
    found = {}
    for match in re.finditer(rf'^{keyword} "([^"]+)"(?: "([^"]+)")? \{{\n(.*?)^\}}', text, re.M | re.S):
        address = ".".join(part for part in match.group(1, 2) if part)
        found[address] = re.sub(r"[ \t]+", " ", match.group(3))
    return found


class DefaultsAddNoResources(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.resources = blocks(read("main.tf"), "resource")
        cls.variables = blocks(read("variables.tf"), "variable")

    def test_existing_resources_are_all_still_there(self):
        self.assertEqual(EXISTING - set(self.resources), set())

    def test_every_new_resource_is_switched(self):
        self.assertEqual(set(self.resources) - EXISTING, set(SWITCHES))
        for address, switch in SWITCHES.items():
            with self.subTest(resource=address):
                self.assertIn(switch, self.resources[address])

    def test_waf_targets_come_only_from_the_two_id_lists(self):
        main = re.sub(r"[ \t]+", " ", read("main.tf"))
        self.assertIn("for id in var.waf_application_gateway_ids : id =>", main)
        self.assertIn("for id in var.waf_front_door_profile_ids : id =>", main)

    def test_switches_default_to_off(self):
        for name, default in OFF_BY_DEFAULT.items():
            with self.subTest(variable=name):
                self.assertRegex(self.variables[name], rf"default = {re.escape(default)}\n")

    def test_entra_default_is_the_previously_hard_coded_list(self):
        default = re.search(r"default = \[(.*?)\]", self.variables["entra_log_categories"], re.S).group(1)
        self.assertEqual(re.findall(r'"([^"]+)"', default), ENTRA_DEFAULT)

    def test_entra_setting_keeps_its_address_on_upgrade(self):
        main = re.sub(r"\s+", " ", read("main.tf"))
        self.assertIn(
            "moved { from = azurerm_monitor_aad_diagnostic_setting.entra_diag_logs "
            "to = azurerm_monitor_aad_diagnostic_setting.entra_diag_logs[0] }",
            main,
        )

    def test_cloud_event_app_settings_are_added_only_with_the_queue(self):
        main = re.sub(r"[ \t]+", " ", read("main.tf"))
        self.assertIn(": name => value if local.cloud_event_queue_configured", main)
        self.assertIn('cloud_event_queue_configured = var.aws_cloud_event_sqs_queue_url != ""', main)


if __name__ == "__main__":
    unittest.main()
