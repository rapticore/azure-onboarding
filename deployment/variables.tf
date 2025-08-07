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

variable "assign_builtin_roles" {
  type = list(object({
    role_name = string
    scope     = string
  }))
  default = []
}