variable "location" {
  type        = string
  description = "Azure region to deploy resources"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group"
}

variable "enable_entra_id_protection_logs" {
  description = <<-EOT
    Opt-in switch (default false) for the two Microsoft Entra ID Protection log
    categories -- RiskyUsers and UserRiskEvents -- on the Entra (aad) diagnostic
    setting. These categories require an Entra ID P2 license; on a tenant without P2
    the diagnostic setting rejects them and `apply` fails. Leave this false unless the
    tenant has Entra ID P2, so a non-P2 apply still succeeds. All the other Entra and
    Activity Log categories are enabled unconditionally.
  EOT
  type        = bool
  default     = false
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

variable "function_storage_account_name" {
  description = <<-EOT
    Optional override for the Function App's storage account name. Leave null (the
    default) to derive a stable name from the subscription id and resource group.
    Set this only when adopting an already-existing storage account -- for example
    when upgrading from an older revision of this module, where the name carried a
    random suffix and changed on every apply. Must be 3-24 lowercase alphanumeric
    characters and globally unique across Azure.
  EOT
  type        = string
  default     = null

  validation {
    condition = (
      var.function_storage_account_name == null ||
      can(regex("^[a-z0-9]{3,24}$", var.function_storage_account_name))
    )
    error_message = "function_storage_account_name must be 3-24 lowercase alphanumeric characters."
  }
}