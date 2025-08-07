module "eventhub" {
  source              = "../modules/rttm"
  
  location            = var.location
  resource_group_name = var.resource_group_name
}

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

  assign_builtin_roles = var.assign_builtin_roles
  custom_permissions = var.custom_permissions

}
