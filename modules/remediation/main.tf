# =====================================================================================
# ⚠️ OPT-IN, DEFAULT-OFF — NOT USED by the standard (single-identity) onboarding.
#    (2026-07-20 product decision.) In the standard model the remediation WRITE
#    permissions are granted on the MAIN scanner role (modules/managed-identity), and
#    Rapticore's remediation engine accepts the scanner identity as the write identity.
#    This module IS wired in deployment/main.tf but provisions NOTHING while
#    `enable_remediation_write = false` (the default). It exists only as an opt-in path
#    for customers who prefer a SEPARATE write identity (two-identity model). Leave
#    `enable_remediation_write = false` for the standard onboarding.
# =====================================================================================
# Rapticore remediation WRITE identity  (OPT-IN, DEFAULT-OFF)
#
# Provisions a SEPARATE user-assigned managed identity used exclusively as the
# remediation write principal. It is deliberately distinct from the read/scanner
# identity in modules/managed-identity: the Rapticore remediation engine refuses to run
# when the configured write client id equals the read client id
# (AZURE_REMEDIATION_WRITE_CLIENT_ID must differ from the scanner client id). Isolating
# write access on its own identity is what lets a customer stay read-only with zero
# write grants, and what bounds the blast radius when writes ARE enabled.
#
# Every resource is gated on var.enable_remediation_write. When it is false the module
# is inert (count = 0) and grants nothing.
#
# Idempotency: no uuid()/timestamp() anywhere. The identity, role and credential names
# are deterministic inputs, so repeated applies are no-ops. This does not reintroduce
# the churn class that was removed from modules/rttm.
# =====================================================================================

locals {
  remediation_enabled = var.enable_remediation_write ? 1 : 0
}

# The dedicated write principal. Its client_id becomes AZURE_REMEDIATION_WRITE_CLIENT_ID.
resource "azurerm_user_assigned_identity" "remediation_write" {
  count               = local.remediation_enabled
  name                = var.identity_name
  resource_group_name = var.resource_group_name
  location            = var.location
}

# Least-privilege custom role: exactly the control-plane ARM actions the shipped Azure
# remediation handlers invoke, and nothing else. Built-in roles were rejected in favour
# of this custom role because the closest built-ins are materially over-broad:
#   * Storage Account Contributor => Microsoft.Storage/storageAccounts/* (adds delete)
#   * Website Contributor         => Microsoft.Web/sites/* (+ serverfarms, certificates)
#   * Network Contributor         => Microsoft.Network/* (every network resource type)
# There is no built-in role scoped to NSG writes alone, so any built-in mix would pull
# in Network Contributor purely to edit NSG rules -- a large, unnecessary grant. This
# custom role adds no delete and no unrelated resource types.
resource "azurerm_role_definition" "remediation_write" {
  count       = local.remediation_enabled
  name        = var.custom_role_name
  scope       = var.role_scope
  description = "Rapticore least-privilege remediation write role: storage / web / NSG write only."

  permissions {
    actions      = var.remediation_write_actions
    not_actions  = []
    data_actions = []
  }

  assignable_scopes = [var.role_scope]
}

resource "azurerm_role_assignment" "remediation_write" {
  count              = local.remediation_enabled
  scope              = var.role_scope
  role_definition_id = azurerm_role_definition.remediation_write[0].role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.remediation_write[0].principal_id
}

# Federated identity credential -- the same inbound OIDC exchange the scanner identity
# uses (azurerm_federated_identity_credential on a user-assigned identity, audience
# api://AzureADTokenExchange). Rapticore's remediation workload presents its OIDC token;
# Azure AD validates it against issuer + subject + audience and issues a token for THIS
# identity. The product's write path authenticates with WorkloadIdentityCredential bound
# to exactly this identity's client id.
resource "azurerm_federated_identity_credential" "remediation_write_oidc" {
  count               = local.remediation_enabled
  name                = var.federated_credential_name
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.remediation_write[0].id
  audience            = [var.federated_credential_audience]
  issuer              = var.federated_credential_issuer
  subject             = var.federated_credential_subject

  lifecycle {
    precondition {
      condition = (
        var.federated_credential_name != "" &&
        var.federated_credential_issuer != "" &&
        var.federated_credential_subject != ""
      )
      error_message = "enable_remediation_write = true requires remediation_federated_credential_name, _issuer and _subject to be set (Rapticore supplies the issuer and subject, exactly as for the scanner identity)."
    }
  }
}
