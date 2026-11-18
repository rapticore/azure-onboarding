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

locals {
  # The Function App is re-published only when zip_deploy_file changes, i.e.
  # when this PATH changes -- not when the archive's content does. Keying the
  # file name on the function's own sources makes a code change reach an
  # existing Function App on the next apply, and only then.
  function_source_files = ["function_app.py", "processor.py", "host.json", "requirements.txt"]
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

  app_settings = {
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
  }

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
resource "azurerm_monitor_aad_diagnostic_setting" "entra_diag_logs" {
  name                           = "rapticore-entra-diag-to-eh${local.rttm_suffix}"
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.entra_diag.id
  eventhub_name                  = azurerm_eventhub.entra_diag.name

  # Directory-plane audit events: app credential/secret adds, OAuth consent grants,
  # new federated credentials, PIM activations, CA-policy changes, role changes. This
  # is the highest-signal identity category and was previously missing, leaving all
  # Entra directory events invisible. AuditLogs itself carries no premium-license
  # requirement, but it rides on this aad setting, which already requires Entra ID P1
  # because of the sign-in categories below.
  enabled_log {
    category = "AuditLogs"
    retention_policy {
      enabled = true
    }
  }

  enabled_log {
    category = "SignInLogs"
    retention_policy {
      enabled = true
    }
  }

  enabled_log {
    category = "NonInteractiveUserSignInLogs"
    retention_policy {
      enabled = true
    }
  }

  enabled_log {
    category = "ServicePrincipalSignInLogs"
    retention_policy {
      enabled = true
    }
  }

  enabled_log {
    category = "ManagedIdentitySignInLogs"
    retention_policy {
      enabled = true
    }
  }

  enabled_log {
    category = "ADFSSignInLogs"
    retention_policy {
      enabled = true
    }
  }

  enabled_log {
    category = "MicrosoftServicePrincipalSignInLogs"
    retention_policy {
      enabled = true
    }
  }

  # Microsoft Entra ID Protection risk detections. These two categories require an
  # Entra ID P2 license, so they are gated behind enable_entra_id_protection_logs
  # (default false); on a non-P2 tenant they would make `apply` fail. When enabled,
  # they surface risky-user state and user risk events for detection.
  dynamic "enabled_log" {
    for_each = var.enable_entra_id_protection_logs ? toset(["RiskyUsers", "UserRiskEvents"]) : toset([])
    content {
      category = enabled_log.value
      retention_policy {
        enabled = true
      }
    }
  }

  depends_on = [azurerm_eventhub_namespace.entra_diag]
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