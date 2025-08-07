data "azurerm_client_config" "current" {}

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.95"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "azurerm" {
  features {}
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

resource "azurerm_application_insights" "function_insights" {
  name                = "appi-rapticore-function"
  location            = var.location
  resource_group_name = var.resource_group_name
  application_type    = "web"
  
  tags = {
    Environment = "Production"
    Purpose     = "FunctionApp-Monitoring"
  }
}

resource "azurerm_service_plan" "function_plan" {
  name                = "plan-rapticore-functions"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"  # Consumption plan
  
  tags = {
    Environment = "Production"
    Purpose     = "FunctionApp-Plan"
  }
}

data "archive_file" "function_code" {
  type        = "zip"
  source_dir  = "${path.module}/eventhub-to-sqs"
  output_path = "${path.module}/eventhub-to-sqs.zip"
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
      python_version = "3.11"  # or "3.8", "3.10", "3.11" based on your function code
    }
    
  }

  app_settings = {
    "FUNCTIONS_EXTENSION_VERSION"       = "~4"
    "FUNCTIONS_WORKER_RUNTIME"          = "python"
    "APPINSIGHTS_INSTRUMENTATIONKEY"    = azurerm_application_insights.function_insights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.function_insights.connection_string
    
    # Event Hub connection settings
    "EventHubConnectionString" = azurerm_eventhub_namespace_authorization_rule.entra_diag.primary_connection_string
    "EventHubName"            = azurerm_eventhub.entra_diag.name
    
    # Additional settings for your function
    "AzureWebJobsStorage"     = azurerm_storage_account.function_storage.primary_connection_string
    "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING" = azurerm_storage_account.function_storage.primary_connection_string
    "WEBSITE_CONTENTSHARE"    = "func-rapticore-entra-processor"
  }


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
  partition_count     = 2
  message_retention   = 7
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