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
# Distinguishes a SECOND (third, …) RTTM deployment inside the same Azure tenant,
# for when one Azure tenant forwards real-time threat events to more than one
# Rapticore tenant. Empty by default so existing deployments keep byte-identical
# resource names and see no state churn.
#
# Several names here are globally unique (the Function App becomes
# <name>.azurewebsites.net, the Event Hub namespace <name>.servicebus.windows.net)
# and the Entra diagnostic setting is unique per Azure tenant, so a second
# deployment WILL collide without this. Use a separate resource group as well.
variable "deployment_suffix" {
  type        = string
  default     = ""
  description = "Suffix appended to RTTM resource names to allow multiple RTTM deployments in one Azure tenant (e.g. \"staging\"). Empty = current names."

  validation {
    condition     = can(regex("^$|^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$", var.deployment_suffix))
    error_message = "deployment_suffix must be empty, or 1-20 lowercase alphanumeric/hyphen characters starting and ending alphanumeric."
  }
}

# --- Optional sources. Each is independent and changes nothing at its default. ------

variable "entra_log_categories" {
  description = <<-EOT
    Entra log categories exported by the tenant diagnostic setting. The default is
    the seven categories this module has always exported, so leaving it unset
    changes nothing. Narrow it to reduce Event Hub volume, or to run on a tenant
    without Entra ID P1/P2: the sign-in categories need P1 or P2, AuditLogs does
    not, so ["AuditLogs"] works on any tenant. An empty list creates no Entra
    diagnostic setting at all (unless enable_entra_id_protection_logs is true).

    NonInteractiveUserSignInLogs and ServicePrincipalSignInLogs can be 5 to 10
    times the volume of SignInLogs. MicrosoftServicePrincipalSignInLogs is high
    volume and Microsoft describes it as not necessary for most customers.

    RiskyUsers and UserRiskEvents are not listed here; they are switched by
    enable_entra_id_protection_logs.
  EOT
  type        = list(string)
  default = [
    "AuditLogs",
    "SignInLogs",
    "NonInteractiveUserSignInLogs",
    "ServicePrincipalSignInLogs",
    "ManagedIdentitySignInLogs",
    "ADFSSignInLogs",
    "MicrosoftServicePrincipalSignInLogs",
  ]

  validation {
    condition = alltrue([
      for category in var.entra_log_categories : contains([
        "AuditLogs",
        "SignInLogs",
        "NonInteractiveUserSignInLogs",
        "ServicePrincipalSignInLogs",
        "ManagedIdentitySignInLogs",
        "ADFSSignInLogs",
        "MicrosoftServicePrincipalSignInLogs",
      ], category)
    ])
    error_message = "entra_log_categories may only contain AuditLogs, SignInLogs, NonInteractiveUserSignInLogs, ServicePrincipalSignInLogs, ManagedIdentitySignInLogs, ADFSSignInLogs and MicrosoftServicePrincipalSignInLogs."
  }
}

variable "waf_application_gateway_ids" {
  description = <<-EOT
    Opt-in (default empty = none). Resource ids of Application Gateways with a web
    application firewall whose ApplicationGatewayFirewallLog is exported to the
    Event Hub. Each gateway must be in the same subscription and the same region
    as this deployment (Azure only streams a regional resource to an Event Hub in
    its own region). Needs aws_cloud_event_sqs_queue_url to be forwarded.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for id in var.waf_application_gateway_ids :
      can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/applicationGateways/[^/]+$", id))
    ])
    error_message = "Each waf_application_gateway_ids entry must be an Application Gateway resource id: /subscriptions/<id>/resourceGroups/<name>/providers/Microsoft.Network/applicationGateways/<name>."
  }
}

variable "waf_front_door_profile_ids" {
  description = <<-EOT
    Opt-in (default empty = none). Resource ids of Azure Front Door profiles whose
    WAF log is exported to the Event Hub. Both generations are accepted and the
    right log category is chosen from the id:
      Front Door Standard/Premium  .../providers/Microsoft.Cdn/profiles/<name>        FrontDoorWebApplicationFirewallLog
      Front Door (classic)         .../providers/Microsoft.Network/frontDoors/<name>  FrontdoorWebApplicationFirewallLog
    Same subscription as this deployment. Needs aws_cloud_event_sqs_queue_url to
    be forwarded.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for id in var.waf_front_door_profile_ids :
      can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/(Microsoft\\.Cdn/profiles|Microsoft\\.Network/frontDoors)/[^/]+$", id))
    ])
    error_message = "Each waf_front_door_profile_ids entry must be a Front Door resource id: .../providers/Microsoft.Cdn/profiles/<name> (Standard/Premium) or .../providers/Microsoft.Network/frontDoors/<name> (classic)."
  }
}

variable "enable_defender_alert_export" {
  description = <<-EOT
    Opt-in (default false). Creates a Defender for Cloud continuous export
    (Microsoft.Security/automations) that sends this subscription's security
    alerts to the Event Hub, with its own Send-only key. Alerts exist only for
    the Defender plans you have turned on. Needs aws_cloud_event_sqs_queue_url to
    be forwarded.
  EOT
  type        = bool
  default     = false
}

variable "aws_cloud_event_sqs_queue_url" {
  description = <<-EOT
    Optional (default empty = not used). The second Rapticore SQS queue, which
    reads WAF and Defender records. Rapticore supplies it and allows aws_role_arn
    to send to it. Without it the Function App counts WAF and Defender records
    and does not forward them; everything else is unaffected.
  EOT
  type        = string
  default     = ""
}

variable "cloud_event_kinds" {
  description = "Record kinds sent to aws_cloud_event_sqs_queue_url instead of aws_sqs_queue_url. Ignored when that queue is empty. Change only when Rapticore asks you to."
  type        = string
  default     = "azure.waf,azure.defender"
}
