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
  source = "../modules/managed-identity"

  identity_name       = var.identity_name
  location            = var.location
  resource_group_name = var.resource_group_name
  role_scope          = var.role_scope

  federated_credential_name     = var.federated_credential_name
  federated_credential_subject  = var.federated_credential_subject
  federated_credential_audience = var.federated_credential_audience
  federated_credential_issuer   = var.federated_credential_issuer

  # Extra Rapticore tenants federating to this same identity (see variables.tf).
  additional_federated_credentials = var.additional_federated_credentials

  assign_builtin_roles = var.assign_builtin_roles
  custom_permissions   = var.custom_permissions
}


module "eventhub" {
  source = "../modules/rttm"

  location            = var.location
  resource_group_name = var.resource_group_name

  enable_entra_id_protection_logs = var.enable_entra_id_protection_logs

  # Optional RTTM sources. Each is independent and changes nothing when left at
  # its default (see variables.tf and the README "Optional sources").
  entra_log_categories          = var.entra_log_categories
  waf_application_gateway_ids   = var.waf_application_gateway_ids
  waf_front_door_profile_ids    = var.waf_front_door_profile_ids
  enable_defender_alert_export  = var.enable_defender_alert_export
  aws_cloud_event_sqs_queue_url = var.aws_cloud_event_sqs_queue_url
  cloud_event_kinds             = var.cloud_event_kinds

  # Set when this Azure tenant already has an RTTM deployment forwarding to a
  # different Rapticore tenant (see variables.tf).
  deployment_suffix = var.rttm_deployment_suffix

  aws_sqs_queue_url    = var.aws_sqs_queue_url
  aws_oidc_audience    = var.aws_oidc_audience
  aws_role_arn         = var.aws_role_arn
  aws_region           = var.aws_region
  msi_client_id        = module.managed_identity.entra_processor_identity_client_id
  msi_full_resource_id = module.managed_identity.entra_processor_identity_id
}


# Remediation WRITE identity -- OPT-IN, DEFAULT-OFF. Creates nothing unless
# enable_remediation_write = true. See modules/remediation and the README.
module "remediation" {
  source = "../modules/remediation"

  enable_remediation_write = var.enable_remediation_write

  location            = var.location
  resource_group_name = var.resource_group_name
  role_scope          = var.remediation_role_scope != "" ? var.remediation_role_scope : var.role_scope

  identity_name    = var.remediation_identity_name
  custom_role_name = var.remediation_custom_role_name

  federated_credential_name     = var.remediation_federated_credential_name
  federated_credential_issuer   = var.remediation_federated_credential_issuer
  federated_credential_subject  = var.remediation_federated_credential_subject
  federated_credential_audience = var.remediation_federated_credential_audience
}


output "remediation_write_enabled" {
  description = "Whether the remediation write identity was provisioned."
  value       = module.remediation.remediation_write_enabled
}

output "remediation_write_client_id" {
  description = "Set as AZURE_REMEDIATION_WRITE_CLIENT_ID (and CloudCapabilityGrant.credentialClientId). Null unless enable_remediation_write = true."
  value       = module.remediation.remediation_write_client_id
}

output "remediation_write_principal_id" {
  description = "Object id of the write identity. Maps to CloudCapabilityGrant.providerPrincipalId. Null unless enabled."
  value       = module.remediation.remediation_write_principal_id
}

output "remediation_write_scope" {
  description = "ARM scope of the write role. Use as CloudCapabilityGrant.selectedScopes for each azure.direct-remediation/<actionId> grant."
  value       = module.remediation.remediation_write_scope
}

output "remediation_write_federated_audience" {
  description = "Audience on the write identity's federated credential (mirrors the scanner audience)."
  value       = module.remediation.remediation_write_federated_audience
}

output "remediation_write_role_definition_id" {
  description = "Resource id of the least-privilege custom remediation write role. Null unless enabled."
  value       = module.remediation.remediation_write_role_definition_id
}
