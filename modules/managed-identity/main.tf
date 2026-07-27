
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

# --- Federated identity credentials (one per Rapticore tenant) -----------------
# ONE Azure tenant can be onboarded to MORE THAN ONE Rapticore tenant. Each
# Rapticore tenant has its own AWS Cognito identity pool and therefore its own
# token `subject`, but they can all federate to this SAME scanning identity —
# Azure allows up to 20 federated credentials per user-assigned identity. That
# is what lets, say, a staging Rapticore tenant and a production one both read
# this subscription without duplicating any Azure resource.
#
# The primary credential is pinned to the STATIC map key "primary" on purpose:
# `moved` block addresses must be static (no variables), and that block is what
# migrates existing state from the pre-for_each singular resource without a
# destroy/recreate of a live credential.
locals {
  federated_credentials = merge(
    {
      primary = {
        name     = var.federated_credential_name
        subject  = var.federated_credential_subject
        audience = var.federated_credential_audience
        issuer   = var.federated_credential_issuer
      }
    },
    {
      for cred in var.additional_federated_credentials : cred.name => {
        name    = cred.name
        subject = cred.subject
        # audience/issuer are identical for every Rapticore tenant, so they
        # default to the primary credential's values.
        audience = coalesce(cred.audience, var.federated_credential_audience)
        issuer   = coalesce(cred.issuer, var.federated_credential_issuer)
      }
    },
  )
}

resource "azurerm_federated_identity_credential" "rapticore_oidc" {
  for_each = local.federated_credentials

  name                = each.value.name
  resource_group_name = var.resource_group_name
  audience            = [each.value.audience]
  issuer              = each.value.issuer
  subject             = each.value.subject
  parent_id           = azurerm_user_assigned_identity.rapticore.id

  lifecycle {
    # Azure rejects duplicate credential names on one identity, and a duplicate
    # SUBJECT would silently mean two Rapticore tenants sharing an identity slot.
    # Caught at plan time rather than as an opaque ARM error at apply time.
    # (Expressed as a precondition rather than `variable validation` because
    # cross-variable references in validation blocks need Terraform >= 1.9.)
    precondition {
      condition     = length(distinct([for c in values(local.federated_credentials) : c.name])) == length(local.federated_credentials)
      error_message = "Federated credential names must be unique. `additional_federated_credentials[*].name` must differ from each other and from `federated_credential_name`."
    }
    precondition {
      condition     = length(distinct([for c in values(local.federated_credentials) : c.subject])) == length(local.federated_credentials)
      error_message = "Federated credential subjects must be unique — each Rapticore tenant has its own Cognito identity id."
    }
  }
}

# State migration for deployments created before this resource became a map.
# Without it, `tofu apply` would destroy and recreate the live credential,
# breaking the existing tenant's scanner until the new one propagates.
moved {
  from = azurerm_federated_identity_credential.rapticore_oidc
  to   = azurerm_federated_identity_credential.rapticore_oidc["primary"]
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
