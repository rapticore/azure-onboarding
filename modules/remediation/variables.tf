variable "enable_remediation_write" {
  description = <<-EOT
    Master opt-in switch for the Rapticore remediation WRITE identity. Defaults to
    false (read-only posture). When false this module creates NO resources and grants
    NO write access whatsoever. Set to true ONLY if you intend to let Rapticore perform
    automated ARM writes (guardrails / one-click / reactive remediation) in this
    subscription. Review the README "Remediation write access" section for the security
    implications before enabling.
  EOT
  type        = bool
  default     = false
}

variable "location" {
  description = "Azure region for the remediation write managed identity."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group that will hold the remediation write managed identity and its federated credential."
  type        = string
}

variable "identity_name" {
  description = <<-EOT
    Name of the user-assigned managed identity used as the dedicated remediation WRITE
    principal. MUST be distinct from the read/scanner identity: the Rapticore
    remediation engine refuses to run when the write client id equals the read client
    id (AZURE_REMEDIATION_WRITE_CLIENT_ID must differ from the scanner client id).
  EOT
  type        = string
  default     = "rapticore-remediation-write-uami"
}

variable "role_scope" {
  description = <<-EOT
    ARM scope at which the least-privilege remediation write role is defined and
    assigned (e.g. "/subscriptions/<sub-id>", or a single resource group for a smaller
    blast radius). This exact value must appear as selectedScopes on the Rapticore
    azure.direct-remediation capability grant.
  EOT
  type        = string
}

variable "custom_role_name" {
  description = <<-EOT
    Name of the tightly-scoped custom role definition created for remediation writes.
    Kept distinct from the scanner's role (RapticoreRemediationRole) so the two never
    collide within the tenant.
  EOT
  type        = string
  default     = "RapticoreRemediationWriteRole"
}

variable "remediation_write_actions" {
  description = <<-EOT
    Control-plane ARM actions granted to the remediation write identity. The default is
    the exact minimum set required by the shipped Azure remediation handlers
    (AZURE_REMEDIATION_ACTIONS in the Rapticore product): storage account read/write +
    key list/regenerate, App Service / Function App (Microsoft.Web/sites) read/write,
    and Network Security Group read/write. It contains no delete and no unrelated
    resource types. Override only to further NARROW this set.
  EOT
  type        = list(string)
  default = [
    "Microsoft.Storage/storageAccounts/read",
    "Microsoft.Storage/storageAccounts/write",
    "Microsoft.Storage/storageAccounts/listkeys/action",
    "Microsoft.Storage/storageAccounts/regeneratekey/action",
    "Microsoft.Web/sites/read",
    "Microsoft.Web/sites/write",
    "Microsoft.Network/networkSecurityGroups/read",
    "Microsoft.Network/networkSecurityGroups/write",
  ]
}

# --- Federated identity credential (OIDC) inputs -------------------------------------
# These identify the EXTERNAL Rapticore workload token that Azure AD trusts for the
# write identity. They mirror the scanner identity's federated credential exactly
# (azurerm_federated_identity_credential on a user-assigned identity, audience
# api://AzureADTokenExchange). They default to empty so a read-only customer
# (enable_remediation_write = false) never has to supply them; when
# enable_remediation_write = true, name/issuer/subject are required and this is enforced
# by a precondition on the credential resource. Rapticore supplies the issuer and
# subject, just as for the scanner.

variable "federated_credential_name" {
  description = "Name of the federated identity credential on the remediation write identity. Rapticore provides this. Required when enable_remediation_write = true."
  type        = string
  default     = ""
}

variable "federated_credential_issuer" {
  description = "OIDC issuer of the Rapticore remediation workload token (same issuer convention as the scanner's federated_credential_issuer). Rapticore provides this. Required when enable_remediation_write = true."
  type        = string
  default     = ""
}

variable "federated_credential_subject" {
  description = <<-EOT
    Subject (sub) claim of the Rapticore remediation workload token. MUST be distinct
    from the scanner identity's subject so this remains a separate principal. Rapticore
    provides this. Required when enable_remediation_write = true.
  EOT
  type        = string
  default     = ""
}

variable "federated_credential_audience" {
  description = <<-EOT
    Audience (aud) the exchanged token must carry. Defaults to the same value the
    scanner uses (api://AzureADTokenExchange). Keep it identical to the scanner's
    federated_credential_audience unless Rapticore instructs otherwise.
  EOT
  type        = string
  default     = "api://AzureADTokenExchange"
}
