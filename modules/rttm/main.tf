data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

data "terraform_remote_state" "uami" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.resource_group_name
    storage_account_name = "rapticoretfstate"
    container_name       = "rapticoretfstatecontainer"
    key                  = "onboarding.terraform.tfstate"
  }
}


resource "azurerm_storage_account" "function_storage" {
  name                     = "funcstorrapticorerttm${substr(uuid(), 0, 2)}"
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
  name                = "rapticore-function-insights-law"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "function_insights" {
  name                = "appi-rapticore-function"
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
  name                = "plan-rapticore-functions"
  resource_group_name = var.resource_group_name
  location            = var.location # Use variable instead of hardcoded
  os_type             = "Linux"
  sku_name            = "Y1"  
  
  tags = {
    Environment = "Production"
    Purpose     = "FunctionApp-Plan"
  }
}

# Create zip file for deployment
data "archive_file" "function_code" {
  type        = "zip"
  source_dir  = "${path.module}/function-app"
  output_path = "${path.module}/function-code.zip"
}

resource "azurerm_linux_function_app" "entra_processor" {
  name                = "func-rapticore-rttm-processor"
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
    "FUNCTIONS_EXTENSION_VERSION"       = "~4"
    "FUNCTIONS_WORKER_RUNTIME"          = "python"
    "APPINSIGHTS_INSTRUMENTATIONKEY"    = azurerm_application_insights.function_insights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.function_insights.connection_string

    # Event Hub connection settings
    "EventHubConnectionString" = azurerm_eventhub_namespace_authorization_rule.entra_diag.primary_connection_string
    "EventHubName"             = azurerm_eventhub.entra_diag.name

    # Azure Storage
    "AzureWebJobsStorage" = azurerm_storage_account.function_storage.primary_connection_string
    "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING" = azurerm_storage_account.function_storage.primary_connection_string
    "WEBSITE_CONTENTSHARE" = "func-rapticore-entra-processor"

    # AWS OIDC configuration (user inputs)
    "AWS_OIDC_AUDIENCE"         = var.aws_oidc_audience
    "AWS_ROLE_ARN"              = var.aws_role_arn
    "AWS_SQS_QUEUE_URL"         = var.aws_sqs_queue_url
    "AWS_REGION"                = var.aws_region

    # Tell the function to look for that setting
    "EVENT_HUB_NAME"            = azurerm_eventhub.entra_diag.name
    "EVENT_HUB_CONSUMER_GROUP"  = azurerm_eventhub_consumer_group.function_consumer.name

    # Enable build during deployment (CRITICAL for Python dependencies)
    "SCM_DO_BUILD_DURING_DEPLOYMENT"  = "true"
    "ENABLE_ORYX_BUILD"               = "true"

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

# Update the blob resource
resource "azurerm_storage_blob" "function_code" {
  name                   = "function-code-${formatdate("YYYY-MM-DD-hhmm", timestamp())}.zip"
  storage_account_name   = azurerm_storage_account.function_storage.name
  storage_container_name = azurerm_storage_container.function_code_container.name
  type                   = "Block"
  source                 = data.archive_file.function_code.output_path
}

# Event Hub Namespace
resource "azurerm_eventhub_namespace" "entra_diag" {
  name                = "eh-entra-rapticore-rttm"
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
resource "azurerm_eventhub_namespace_authorization_rule" "entra_diag" {
  name                = "RootManageSharedAccessKey${substr(uuid(), 0, 2)}"
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
  name                           = "rapticore-entra-diag-to-eh"
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.entra_diag.id
  eventhub_name                  = azurerm_eventhub.entra_diag.name
  
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

  depends_on = [azurerm_eventhub_namespace.entra_diag]
}

# Activity Log Diagnostic Settings for NSG Flow Logs
resource "azurerm_monitor_diagnostic_setting" "activity_log_nsg" {
  name                           = "rapticore-activity-log-nsg-to-eh"
  target_resource_id             = data.azurerm_subscription.current.id
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.entra_diag.id
  eventhub_name                  = azurerm_eventhub.entra_diag.name

  enabled_log {
    category = "Administrative"
  }

  depends_on = [azurerm_eventhub_namespace.entra_diag]
}

# Output values for reference
output "function_app_name" {
  value = azurerm_linux_function_app.entra_processor.name
  description = "Name of the Function App"
}

output "eventhub_connection_string" {
  value     = azurerm_eventhub_namespace_authorization_rule.entra_diag.primary_connection_string
  sensitive = true
  description = "Event Hub connection string"
}

output "function_app_url" {
  value = "https://${azurerm_linux_function_app.entra_processor.default_hostname}"
  description = "Function App URL"
}

output "activity_log_diagnostic_setting_id" {
  value       = azurerm_monitor_diagnostic_setting.activity_log_nsg.id
  description = "Activity Log diagnostic setting ID"
}