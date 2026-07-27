variable "identity_name" {
  type        = string
  description = "Name of the managed identity"
}

variable "location" {
  type        = string
  description = "Azure region"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group where identity will be created"
}

variable "role_scope" {
  type        = string
  description = "Scope for the custom role assignment (e.g., subscription or resource group)"
}

variable "custom_permissions" {
  type        = list(string)
  description = "List of permissions for the custom role"
}

# Microsoft Graph APPLICATION permissions (app roles) granted to the scanning
# identity so Rapticore can read the Entra directory — users, groups, group
# memberships, and directory roles / PIM. This is the input for the identity and
# inherited-admin analysis; without it the scanner sees resources but not who is
# in which group. Required baseline for every client onboarding.
variable "graph_app_roles" {
  type = list(string)
  default = [
    "Directory.Read.All",
    "GroupMember.Read.All",
    "RoleManagement.Read.Directory",
  ]
}

# Federated Identity Credential Inputs
variable "federated_credential_name" {
  type        = string
  description = "Name of the federated identity credential"
}

variable "federated_credential_subject" {
  type        = string
  description = "Subject identifier in the token (e.g. 'repo:org/repo:ref:refs/heads/main')"
}

variable "federated_credential_audience" {
  type        = string
  description = "Audience for the token (e.g. 'api://AzureADTokenExchange')"
}

variable "federated_credential_issuer" {
  type        = string
  description = "OIDC issuer (e.g., 'https://token.actions.githubusercontent.com')"
}

# Extra federated credentials on the SAME scanning identity — one per additional
# Rapticore tenant reading this Azure tenant. See the `locals` block in main.tf.
variable "additional_federated_credentials" {
  type = list(object({
    name     = string
    subject  = string
    audience = optional(string)
    issuer   = optional(string)
  }))
  default     = []
  description = <<-EOT
    Additional Rapticore tenants that should be able to scan this Azure tenant
    with the same managed identity (Azure allows up to 20 federated credentials
    per identity). Rapticore supplies a distinct `subject` per tenant — that
    tenant's Cognito identity id. `audience` and `issuer` may be omitted; they
    default to the primary credential's values, which is correct for every
    Rapticore tenant. Names must be unique and must differ from
    `federated_credential_name`.
  EOT

  validation {
    condition     = length(distinct([for c in var.additional_federated_credentials : c.name])) == length(var.additional_federated_credentials)
    error_message = "additional_federated_credentials[*].name must be unique."
  }

  validation {
    condition     = alltrue([for c in var.additional_federated_credentials : trimspace(c.subject) != ""])
    error_message = "Every additional federated credential needs a non-empty subject (the Rapticore tenant's Cognito identity id)."
  }
}

variable "assign_builtin_roles" {
  type = list(object({
    role_name = string
    scope     = string
  }))
  default = []
}