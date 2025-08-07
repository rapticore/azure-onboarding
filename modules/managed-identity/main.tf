terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.95"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_user_assigned_identity" "rapticore" {
  name                = var.identity_name
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_role_assignment" "builtin" {
  for_each             = { for role in var.assign_builtin_roles : "${role.role_name}-${role.scope}" => role }
  scope                = each.value.scope
  role_definition_name = each.value.role_name
  principal_id         = azurerm_user_assigned_identity.rapticore.principal_id
}

resource "azurerm_role_definition" "rapticore_custom" {
  name        = "rapticore-remediation-role"
  scope       = var.role_scope
  description = "Custom role for Rapticore with FullRead access"

  permissions {
    actions     = var.custom_permissions
    not_actions = []
  }

  assignable_scopes = [var.role_scope]
}

resource "azurerm_role_assignment" "rapticore_assignment" {
  principal_id         = azurerm_user_assigned_identity.rapticore.principal_id
  role_definition_id   = azurerm_role_definition.rapticore_custom.role_definition_resource_id
  scope                = var.role_scope
}

resource "azurerm_federated_identity_credential" "rapticore_oidc" {
  name                        = var.federated_credential_name
  resource_group_name         = var.resource_group_name
  audience                    = [var.federated_credential_audience]
  issuer                      = var.federated_credential_issuer
  subject                     = var.federated_credential_subject
  parent_id                   = azurerm_user_assigned_identity.rapticore.id
}
