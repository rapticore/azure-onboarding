variable "location" {
  type        = string
  description = "Azure region to deploy resources"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group"
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