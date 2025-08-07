provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

variable "location" {
  default = "eastus"
  type = string
  description = "Azure region to deploy resources"
}

variable "resource_group_name" {
}

variable "storage_account_name" {
  default = "rapticorerttmtfstate" # must be globally unique
}

variable "container_name" {
  default = "rapticorerttmtfstatecontainer"
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription id"
}


resource "azurerm_storage_account" "tfstate" {
  name                     = var.storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "tfstate" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}
