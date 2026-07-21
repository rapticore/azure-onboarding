
provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

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
  name        = "RapticoreRemediationRole"
  scope       = var.role_scope
  description = "Custom role for Rapticore with FullRead access"

  permissions {
    actions     = var.custom_permissions
    not_actions = []
  }

  assignable_scopes = [var.role_scope]
}

resource "azurerm_role_assignment" "rapticore_assignment" {
  principal_id       = azurerm_user_assigned_identity.rapticore.principal_id
  role_definition_id = azurerm_role_definition.rapticore_custom.role_definition_resource_id
  scope              = var.role_scope
}

resource "azurerm_federated_identity_credential" "rapticore_oidc" {
  name                = var.federated_credential_name
  resource_group_name = var.resource_group_name
  audience            = [var.federated_credential_audience]
  issuer              = var.federated_credential_issuer
  subject             = var.federated_credential_subject
  parent_id           = azurerm_user_assigned_identity.rapticore.id
}

# --- Microsoft Graph directory-read permissions for the scanning identity -------
# Grants Rapticore read access to the Entra directory (users, groups, group
# memberships, directory roles / PIM). Assigning a Graph app role to the identity
# IS the admin consent, so applying THIS block requires an Entra admin role
# (Global Administrator or Privileged Role Administrator) — the ARM resources
# above only need subscription Owner. Without these app roles Rapticore can
# enumerate resources but not directory membership, so identity and
# inherited-permission analysis would be incomplete.
data "azuread_service_principal" "msgraph" {
  # azuread ~> 2.0 uses `application_id`; on the azuread 3.x provider rename to `client_id`.
  application_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph (well-known app id)
}

resource "azuread_app_role_assignment" "graph_read" {
  for_each            = toset(var.graph_app_roles)
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids[each.value]
  principal_object_id = azurerm_user_assigned_identity.rapticore.principal_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

resource "azuread_application" "rapticore_app" {
  display_name = "azure_aws_assume_role"

  identifier_uris = [
    "api://${data.azurerm_client_config.current.tenant_id}"
  ]

  # Define custom App Role
  app_role {
    allowed_member_types = ["Application", "User"]
    description          = "Role for Rapticore RTTM Managed Identity"
    display_name         = "RapticoreRTTMRole"
    enabled              = true
    id                   = uuid()
    value                = "Rapticore.Function.Access"
  }
}

resource "azuread_service_principal" "rapticore_sp" {
  client_id = azuread_application.rapticore_app.client_id
}

resource "azuread_app_role_assignment" "rapticore_assignment" {
  principal_object_id = azurerm_user_assigned_identity.rapticore.principal_id
  resource_object_id  = azuread_service_principal.rapticore_sp.id
  app_role_id         = tolist(azuread_application.rapticore_app.app_role)[0].id
}


output "rapticore_app_id" {
  description = "App Registration client ID"
  value       = azuread_application.rapticore_app.id
}

output "rapticore_app_uri" {
  description = "Application ID URI (use this as AWS_OIDC_AUDIENCE)"
  value       = azuread_application.rapticore_app.identifier_uris
}

output "rapticore_service_principal_id" {
  description = "Service Principal Object ID"
  value       = azuread_service_principal.rapticore_sp.id
}

output "entra_processor_identity_id" {
  value = azurerm_user_assigned_identity.rapticore.id
}

output "entra_processor_identity_client_id" {
  value = azurerm_user_assigned_identity.rapticore.client_id
}
