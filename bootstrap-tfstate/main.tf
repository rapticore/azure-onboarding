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
  type        = string
  description = "Name of the existing resource group"
}

variable "storage_account_name" {
  type        = string
  description = "Name of the storage account used for Terraform state"
  validation {
    condition     = length(var.storage_account_name) == 24 && can(regex("^[a-z0-9]+$", var.storage_account_name))
    error_message = "Storage account name must be exactly 24 characters long and contain only lowercase letters and numbers."
  }
}

variable "container_name" {
  type        = string
  description = "Name of the container used for Terraform state"
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.container_name)) && length(var.container_name) <= 63
    error_message = "Container name must contain only lowercase letters and numbers, and be at most 63 characters long."
  }
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
