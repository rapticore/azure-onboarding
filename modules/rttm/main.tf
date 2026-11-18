data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}


# Deterministic, collision-resistant suffix for globally-unique names.
#
# This MUST NOT use uuid(): uuid() returns a new value on every evaluation, so using it
# in a resource argument produces a perpetual diff and Terraform destroys and recreates
# the storage account on EVERY apply. HashiCorp documents this explicitly ("using it
# directly in resource arguments will result in spurious diffs").
#
# A hash of subscription id + resource group is preferred over random_string/random_id
# here because it is reproducible from inputs alone: if the remote state is ever lost or
# recreated, the same names are derived again instead of orphaning the live resources.
# 11 hex chars = 16^11 (~1.8e13) combinations, which is what makes the globally-unique
# storage account name safe across customers. The previous 2-char suffix allowed only
# 256 distinct names for all Rapticore customers combined.
locals {
  # Optional per-deployment name suffix. Empty by default, so every existing
  # deployment keeps byte-identical resource names and sees NO state churn.
  #
  # Set it when ONE Azure tenant forwards RTTM to more than one Rapticore tenant
  # (e.g. a staging tenant alongside production): every name below is either
  # globally unique (function app, Event Hub namespace), tenant-unique (the
  # Entra diagnostic setting) or resource-group unique, so a second deployment
  # collides without it. Pair it with a separate resource group.
  rttm_suffix = var.deployment_suffix == "" ? "" : "-${var.deployment_suffix}"

  rttm_name_seed = sha256(
    "rapticore-rttm-${data.azurerm_subscription.current.subscription_id}-${var.resource_group_name}${local.rttm_suffix}"
  )
  # Storage account names: 3-24 chars, lowercase letters and digits only.
  # "rapticorerttm" (13) + 11 hex chars = 24. The suffix is folded into the seed
  # above rather than appended, to stay inside the 24-char limit.
  function_storage_name = coalesce(
    var.function_storage_account_name,
    "rapticorerttm${substr(local.rttm_name_seed, 0, 11)}",
  )
}

resource "azurerm_storage_account" "function_storage" {
  name                     = local.function_storage_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    Environment = "Production"
    Purpose     = "FunctionApp-Storage"
  }
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "rapticore-function-insights-law${local.rttm_suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "function_insights" {
  name                = "appi-rapticore-function${local.rttm_suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.law.id

  tags = {
    Environment = "Production"
    Purpose     = "FunctionApp-Monitoring"
  }
}

resource "azurerm_service_plan" "function_plan" {
  name                = "plan-rapticore-functions${local.rttm_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location # Use variable instead of hardcoded
  os_type             = "Linux"
  sku_name            = "Y1"

  tags = {
    Environment = "Production"
    Purpose     = "FunctionApp-Plan"
  }
}

# Optional sources (Entra category selection, WAF logs, Defender alerts) and the
# second Rapticore queue. With every new variable left at its default, each
# value below is what the module used before they existed.
locals {
  # Entra categories on the tenant diagnostic setting. The default list is the
  # seven categories that were previously hard-coded, so nothing changes unless
  # the caller narrows it.
  entra_log_categories = distinct(concat(
    var.entra_log_categories,
    var.enable_entra_id_protection_logs ? ["RiskyUsers", "UserRiskEvents"] : [],
  ))

  # Resource id -> WAF log category. Front Door Standard/Premium
  # (Microsoft.Cdn/profiles) and Front Door classic (Microsoft.Network/frontDoors)
  # spell the category differently:
  # https://learn.microsoft.com/azure/web-application-firewall/afds/waf-front-door-monitor
  waf_log_targets = merge(
    { for id in var.waf_application_gateway_ids : id => "ApplicationGatewayFirewallLog" },
    {
      for id in var.waf_front_door_profile_ids : id => (
        can(regex("(?i)/providers/microsoft\\.network/frontdoors/", id))
        ? "FrontdoorWebApplicationFirewallLog"
        : "FrontDoorWebApplicationFirewallLog"
      )
    },
  )

  cloud_event_queue_configured = var.aws_cloud_event_sqs_queue_url != ""

  # Added to the Function App only when the second queue is configured, so a
  # deployment that does not use it keeps exactly the app settings it had.
  cloud_event_app_settings = {
    for name, value in {
      "AWS_CLOUD_EVENT_SQS_QUEUE_URL" = var.aws_cloud_event_sqs_queue_url
      "CLOUD_EVENT_KINDS"             = var.cloud_event_kinds
      # WAF and Defender records do not carry the tenant id; Rapticore finds
      # the account by it.
      "AZURE_TENANT_ID" = data.azurerm_client_config.current.tenant_id
    } : name => value if local.cloud_event_queue_configured
  }

  # The Function App is re-published only when zip_deploy_file changes, i.e.
  # when this PATH changes -- not when the archive's content does. Keying the
  # file name on the function's own sources makes a code change reach an
  # existing Function App on the next apply, and only then. (Installed
  # dependencies under .python_packages are covered by requirements.txt.)
  function_source_files = ["function_app.py", "processor.py", "routing.py", "host.json", "requirements.txt"]
  function_source_hash = substr(sha256(join("", [
    for name in local.function_source_files : filesha256("${path.module}/function-app/${name}")
  ])), 0, 12)
}

# Create zip file for deployment
data "archive_file" "function_code" {
  type        = "zip"
  source_dir  = "${path.module}/function-app"
  output_path = "${path.module}/function-code-${local.function_source_hash}.zip"
}

resource "azurerm_linux_function_app" "entra_processor" {
  name                = "func-rapticore-rttm-processor${local.rttm_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location

  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key
  service_plan_id            = azurerm_service_plan.function_plan.id

  site_config {
    application_stack {
      python_version = "3.12"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.msi_full_resource_id]
  }

  app_settings = merge({
    "FUNCTIONS_EXTENSION_VERSION"           = "~4"
    "FUNCTIONS_WORKER_RUNTIME"              = "python"
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.function_insights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.function_insights.connection_string

    # Event Hub connection settings
    "EventHubConnectionString" = azurerm_eventhub_namespace_authorization_rule.entra_diag.primary_connection_string
    "EventHubName"             = azurerm_eventhub.entra_diag.name

    # Azure Storage
    "AzureWebJobsStorage"                      = azurerm_storage_account.function_storage.primary_connection_string
    "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING" = azurerm_storage_account.function_storage.primary_connection_string
    "WEBSITE_CONTENTSHARE"                     = "func-rapticore-entra-processor"

    # AWS OIDC configuration (user inputs)
    "AWS_OIDC_AUDIENCE" = var.aws_oidc_audience
    "AWS_ROLE_ARN"      = var.aws_role_arn
    "AWS_SQS_QUEUE_URL" = var.aws_sqs_queue_url
    "AWS_REGION"        = var.aws_region

    # Tell the function to look for that setting
    "EVENT_HUB_NAME"           = azurerm_eventhub.entra_diag.name
    "EVENT_HUB_CONSUMER_GROUP" = azurerm_eventhub_consumer_group.function_consumer.name

    # Enable build during deployment (CRITICAL for Python dependencies)
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "ENABLE_ORYX_BUILD"              = "true"

    # Optional MSI Client ID
    "MSI_CLIENT_ID" = var.msi_client_id

    # REMOVE these WEBSITE_RUN_FROM_PACKAGE settings for direct deployment
    # "WEBSITE_RUN_FROM_PACKAGE" = "https://${azurerm_storage_account.function_storage.name}.blob.core.windows.net/${azurerm_storage_container.function_code_container.name}/${azurerm_storage_blob.function_code.name}"
    # "WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID" = var.msi_full_resource_id
    "WEBSITE_RUN_FROM_PACKAGE" = "1"
  }, local.cloud_event_app_settings)

  # Use zip_deploy for direct deployment
  zip_deploy_file = data.archive_file.function_code.output_path

  tags = {
    Environment = "Production"
    Purpose     = "Entra-Log-Processor"
  }

  depends_on = [
    azurerm_eventhub.entra_diag,
    azurerm_storage_account.function_storage,
    azurerm_application_insights.function_insights
  ]
}


resource "azurerm_storage_container" "function_code_container" {
  name                  = "function-code"
  storage_account_name  = azurerm_storage_account.function_storage.name
  container_access_type = "private"
}

# Content-addressed blob name.
#
# This MUST NOT use timestamp(): timestamp() is evaluated at apply time, so the blob was
# renamed on every apply -- a permanent diff that uploaded a duplicate copy of identical
# code each run and never removed the previous ones. Keying the name on the archive's
# SHA1 means the name changes if and only if the function code actually changes.
resource "azurerm_storage_blob" "function_code" {
  name                   = "function-code-${data.archive_file.function_code.output_sha}.zip"
  storage_account_name   = azurerm_storage_account.function_storage.name
  storage_container_name = azurerm_storage_container.function_code_container.name
  type                   = "Block"
  source                 = data.archive_file.function_code.output_path
}

# Event Hub Namespace
resource "azurerm_eventhub_namespace" "entra_diag" {
  name                = "eh-entra-rapticore-rttm${local.rttm_suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  capacity            = 1

  tags = {
    Environment = "Production"
    Purpose     = "Entra-Diagnostics"
  }
}

# Event Hub
resource "azurerm_eventhub" "entra_diag" {
  name                = "rapticore-entra-diag-logs"
  namespace_name      = azurerm_eventhub_namespace.entra_diag.name
  resource_group_name = var.resource_group_name
  partition_count     = 4
  message_retention   = 1
}

# Event Hub Authorization Rule
#
# Named explicitly rather than "RootManageSharedAccessKey<uuid()>". The uuid() suffix was
# presumably there to avoid colliding with the rule Azure auto-creates on every namespace
# (which is literally named RootManageSharedAccessKey), but it made the rule -- and
# therefore the connection string consumed by the Function App and both diagnostic
# settings below -- churn on every apply. A distinct, stable name avoids the collision
# without the churn. Authorization rule names are scoped to the namespace, so no global
# uniqueness is required here.
#
# listen + send + manage are all required, not over-permissive: Azure Monitor diagnostic
# settings that stream to an Event Hub require Manage, Send and Listen on the referenced
# authorization rule (the platform calls ListKeys on it). Do not narrow these.
resource "azurerm_eventhub_namespace_authorization_rule" "entra_diag" {
  name                = "rapticore-rttm-diagnostics"
  namespace_name      = azurerm_eventhub_namespace.entra_diag.name
  resource_group_name = var.resource_group_name
  listen              = true
  send                = true
  manage              = true
}

# Consumer Group for Function App (best practice to have dedicated consumer group)
resource "azurerm_eventhub_consumer_group" "function_consumer" {
  name                = "function-consumer-group"
  namespace_name      = azurerm_eventhub_namespace.entra_diag.name
  eventhub_name       = azurerm_eventhub.entra_diag.name
  resource_group_name = var.resource_group_name
}

# Entra ID Diagnostic Settings
#
# Categories come from var.entra_log_categories (default: the seven that were
# hard-coded here before the variable existed) plus, behind
# enable_entra_id_protection_logs, the two Entra ID Protection categories.
#
#   AuditLogs -- directory-plane audit events: app credential/secret adds, OAuth
#     consent grants, new federated credentials, PIM activations, CA-policy
#     changes, role changes. The highest-signal identity category. It carries no
#     premium-license requirement on its own.
#   SignInLogs, NonInteractiveUserSignInLogs, ServicePrincipalSignInLogs,
#   ManagedIdentitySignInLogs, ADFSSignInLogs, MicrosoftServicePrincipalSignInLogs
#     -- sign-in activity. Exporting these requires Entra ID P1 or P2.
#   RiskyUsers, UserRiskEvents -- Microsoft Entra ID Protection risk detections.
#     These require an Entra ID P2 license, so they are gated behind
#     enable_entra_id_protection_logs (default false); on a non-P2 tenant they
#     would make `apply` fail.
#
# An empty category list (and no ID Protection logs) creates no setting at all,
# for tenants that cannot or do not want to export Entra logs.
resource "azurerm_monitor_aad_diagnostic_setting" "entra_diag_logs" {
  count = length(local.entra_log_categories) > 0 ? 1 : 0

  name                           = "rapticore-entra-diag-to-eh${local.rttm_suffix}"
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.entra_diag.id
  eventhub_name                  = azurerm_eventhub.entra_diag.name

  dynamic "enabled_log" {
    for_each = toset(local.entra_log_categories)
    content {
      category = enabled_log.value
      retention_policy {
        enabled = true
      }
    }
  }

  depends_on = [azurerm_eventhub_namespace.entra_diag]
}

# The setting had no `count` before entra_log_categories existed. This keeps the
# existing setting in place on upgrade (no destroy/recreate).
moved {
  from = azurerm_monitor_aad_diagnostic_setting.entra_diag_logs
  to   = azurerm_monitor_aad_diagnostic_setting.entra_diag_logs[0]
}

# Activity Log Diagnostic Settings for NSG Flow Logs
resource "azurerm_monitor_diagnostic_setting" "activity_log_nsg" {
  name                           = "rapticore-activity-log-nsg-to-eh${local.rttm_suffix}"
  target_resource_id             = data.azurerm_subscription.current.id
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.entra_diag.id
  eventhub_name                  = azurerm_eventhub.entra_diag.name

  # Administrative = all ARM create/update/delete/action operations (incl. RBAC changes).
  enabled_log {
    category = "Administrative"
  }

  # Broader control-plane categories. All are Activity Log categories with no license
  # requirement (they work on any subscription), and are empty rather than erroring when
  # the underlying source is absent:
  #   Security = Microsoft Defender for Cloud alerts
  #   Policy   = Azure Policy audit/deny effect operations
  #   Alert    = activations of Azure alert rules
  enabled_log {
    category = "Security"
  }

  enabled_log {
    category = "Policy"
  }

  enabled_log {
    category = "Alert"
  }

  depends_on = [azurerm_eventhub_namespace.entra_diag]
}

# WAF logs (optional, off by default): one diagnostic setting per named
# Application Gateway or Front Door, exporting ONLY the firewall log category.
# Access logs are far larger and nothing reads them.
#
# Azure constraints (https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings):
#   * a regional resource (Application Gateway) can only stream to an Event Hub
#     in its own region, so the gateway must be in var.location;
#   * a resource can have at most five diagnostic settings.
resource "azurerm_monitor_diagnostic_setting" "waf_logs" {
  for_each = local.waf_log_targets

  name                           = "rapticore-waf-log-to-eh${local.rttm_suffix}"
  target_resource_id             = each.key
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.entra_diag.id
  eventhub_name                  = azurerm_eventhub.entra_diag.name

  enabled_log {
    category = each.value
  }

  # Only the firewall log category is managed here. Azure reports the
  # resource's metric categories back on read; they are not this module's.
  lifecycle {
    ignore_changes = [metric]
  }

  depends_on = [azurerm_eventhub_namespace.entra_diag]
}

# Defender for Cloud continuous export of security alerts (optional, off by
# default). Continuous export authenticates with a connection string rather than
# through Azure Monitor, so it gets its own Send-only rule scoped to the hub.
resource "azurerm_eventhub_authorization_rule" "defender_send" {
  count = var.enable_defender_alert_export ? 1 : 0

  name                = "rapticore-defender-send"
  namespace_name      = azurerm_eventhub_namespace.entra_diag.name
  eventhub_name       = azurerm_eventhub.entra_diag.name
  resource_group_name = var.resource_group_name
  listen              = false
  send                = true
  manage              = false
}

# No rule_set = every alert of the subscription. The name is deliberately NOT
# "ExportToEventHub": that is the name the Azure portal's Continuous export page
# owns, and taking it would overwrite an export you may already have configured
# there. This one is listed under the resource group as a Security automation.
resource "azurerm_security_center_automation" "defender_alerts" {
  count = var.enable_defender_alert_export ? 1 : 0

  name                = "rapticore-defender-alert-export${local.rttm_suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  description         = "Rapticore: security alerts to the real-time threat monitoring Event Hub"

  scopes = [data.azurerm_subscription.current.id]

  source {
    event_source = "Alerts"
  }

  action {
    type              = "eventhub"
    resource_id       = azurerm_eventhub.entra_diag.id
    connection_string = azurerm_eventhub_authorization_rule.defender_send[0].primary_connection_string
  }
}

# WAF and Defender records are read only from the cloud-event queue. Exporting
# them without it costs Event Hub events and delivers nothing, so say so at plan
# time (a warning, not an error: the export can be staged ahead of the queue).
check "cloud_event_queue_for_waf_and_defender" {
  assert {
    condition = (
      local.cloud_event_queue_configured ||
      (length(local.waf_log_targets) == 0 && !var.enable_defender_alert_export)
    )
    error_message = "WAF logs or Defender alerts are exported but aws_cloud_event_sqs_queue_url is empty: the Function App will count these records and not forward them. Ask Rapticore for the cloud-event queue URL."
  }
}

# Output values for reference
output "function_app_name" {
  value       = azurerm_linux_function_app.entra_processor.name
  description = "Name of the Function App"
}

output "eventhub_connection_string" {
  value       = azurerm_eventhub_namespace_authorization_rule.entra_diag.primary_connection_string
  sensitive   = true
  description = "Event Hub connection string"
}

output "function_app_url" {
  value       = "https://${azurerm_linux_function_app.entra_processor.default_hostname}"
  description = "Function App URL"
}

output "activity_log_diagnostic_setting_id" {
  value       = azurerm_monitor_diagnostic_setting.activity_log_nsg.id
  description = "Activity Log diagnostic setting ID"
}

output "entra_log_categories" {
  value       = local.entra_log_categories
  description = "Entra log categories exported to the Event Hub (empty = no Entra diagnostic setting)"
}

output "waf_log_targets" {
  value       = local.waf_log_targets
  description = "Resource id => WAF log category for each Application Gateway / Front Door exporting WAF logs"
}

output "defender_alert_export_enabled" {
  value       = var.enable_defender_alert_export
  description = "Whether Defender for Cloud security alerts are exported to the Event Hub"
}

output "cloud_event_queue_configured" {
  value       = local.cloud_event_queue_configured
  description = "Whether WAF and Defender records have a queue to be forwarded to"
}
