terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.95"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.0"
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

provider "azuread" {}


module "managed_identity" {
  source              = "../modules/managed-identity"

  identity_name                     = var.identity_name
  location                          = var.location
  resource_group_name               = var.resource_group_name
  role_scope                        = var.role_scope

  federated_credential_name         = var.federated_credential_name
  federated_credential_subject      = var.federated_credential_subject
  federated_credential_audience     = var.federated_credential_audience
  federated_credential_issuer       = var.federated_credential_issuer

  assign_builtin_roles              = var.assign_builtin_roles
  custom_permissions                = var.custom_permissions
}


module "eventhub" {
  source                = "../modules/rttm"
  
  location              = var.location
  resource_group_name   = var.resource_group_name

  aws_sqs_queue_url     = var.aws_sqs_queue_url
  aws_oidc_audience     = var.aws_oidc_audience
  aws_role_arn          = var.aws_role_arn
  aws_region            = var.aws_region
  msi_client_id         = module.managed_identity.entra_processor_identity_client_id
  msi_full_resource_id  = module.managed_identity.entra_processor_identity_id
}
