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

variable "additional_federated_credentials" {
  type = list(object({
    name     = string
    subject  = string
    audience = optional(string)
    issuer   = optional(string)
  }))
  default     = []
  description = <<-EOT
    Onboard this Azure tenant to MORE THAN ONE Rapticore tenant using the same
    scanning identity — e.g. a staging Rapticore tenant alongside production.
    Each Rapticore tenant has its own Cognito identity pool and therefore its
    own `subject`, which Rapticore supplies. `audience`/`issuer` may be omitted
    (they default to the primary credential's values). No extra Azure resources
    are created; Azure allows up to 20 federated credentials per identity.
  EOT
}

variable "assign_builtin_roles" {
  type = list(object({
    role_name = string
    scope     = string
  }))
  default = []
}

variable "aws_oidc_audience" {
  description = "AWS OIDC Audience (aud claim AWS expects, matches OIDC provider in AWS IAM)"
  type        = string
}

variable "aws_role_arn" {
  description = "AWS IAM role ARN that Azure Function should assume"
  type        = string
}

variable "aws_sqs_queue_url" {
  description = "Target SQS queue URL"
  type        = string
}

variable "aws_region" {
  description = "AWS region for boto3 session"
  type        = string
  default     = "us-west-2"
}

variable "msi_client_id" {
  description = "User-assigned MSI Client ID (optional). Leave blank for system-assigned."
  type        = string
  default     = null
}

variable "msi_full_resource_id" {
  description = "User-assigned MSI full resource ID (optional)"
  type        = string
  default     = null
}

# --- RTTM: Entra ID Protection risk logs (opt-in, needs Entra ID P2) ----------------
variable "enable_entra_id_protection_logs" {
  description = <<-EOT
    Opt-in (default false) for the RiskyUsers and UserRiskEvents Entra diagnostic
    categories. Requires an Entra ID P2 license; leave false on non-P2 tenants so the
    apply still succeeds. All other Entra and Activity Log categories are always on.
  EOT
  type        = bool
  default     = false
}

# --- Remediation WRITE identity (opt-in, default off) -------------------------------
variable "enable_remediation_write" {
  description = <<-EOT
    Master opt-in switch (default false) for the dedicated remediation WRITE identity.
    When false, no write identity, role or credential is created and Rapticore keeps
    read-only posture. Set true ONLY to allow automated ARM writes (guardrails /
    one-click / reactive remediation). See the README "Remediation write access".
  EOT
  type        = bool
  default     = false
}

variable "remediation_role_scope" {
  description = <<-EOT
    Optional ARM scope for the remediation write role. Leave empty ("") to reuse
    role_scope (the scanner scope, usually the subscription). Set to a single resource
    group to give the write identity a smaller blast radius than the read identity.
  EOT
  type        = string
  default     = ""
}

variable "remediation_identity_name" {
  description = "Name of the remediation write user-assigned managed identity."
  type        = string
  default     = "rapticore-remediation-write-uami"
}

variable "remediation_custom_role_name" {
  description = "Name of the least-privilege custom role for remediation writes (kept distinct from the scanner role)."
  type        = string
  default     = "RapticoreRemediationWriteRole"
}

variable "remediation_federated_credential_name" {
  description = "Federated credential name on the write identity. Rapticore provides this. Required when enable_remediation_write = true."
  type        = string
  default     = ""
}

variable "remediation_federated_credential_issuer" {
  description = "OIDC issuer for the write identity (same convention as the scanner's federated_credential_issuer). Rapticore provides this. Required when enable_remediation_write = true."
  type        = string
  default     = ""
}

variable "remediation_federated_credential_subject" {
  description = "OIDC subject for the write identity. MUST differ from the scanner subject. Rapticore provides this. Required when enable_remediation_write = true."
  type        = string
  default     = ""
}

variable "remediation_federated_credential_audience" {
  description = "OIDC audience for the write identity. Defaults to api://AzureADTokenExchange; keep identical to the scanner's federated_credential_audience."
  type        = string
  default     = "api://AzureADTokenExchange"
}
variable "rttm_deployment_suffix" {
  type        = string
  default     = ""
  description = <<-EOT
    Set ONLY when this Azure tenant already forwards RTTM events to a different
    Rapticore tenant and you are standing up a second, parallel forwarder (e.g.
    "staging"). Suffixes the RTTM resource names so the second deployment does
    not collide — the Function App and Event Hub namespace names are globally
    unique and the Entra diagnostic setting is unique per Azure tenant. Use a
    separate `resource_group_name` and a separate Terraform state key too.

    Leave empty for a normal single-tenant onboarding; empty preserves the
    existing resource names exactly.

    Cost note: a second forwarder duplicates the Event Hub namespace, Function
    App, storage account and Log Analytics workspace, and streams the SAME Entra
    diagnostic logs twice. If you only need to point RTTM at a DIFFERENT
    Rapticore tenant (rather than at both simultaneously), it is cheaper to
    repoint the existing deployment's `aws_sqs_queue_url` / `aws_role_arn`.
  EOT
}
