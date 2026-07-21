output "remediation_write_enabled" {
  description = "Whether the remediation write identity was provisioned."
  value       = var.enable_remediation_write
}

output "remediation_write_client_id" {
  description = <<-EOT
    Client (application) id of the remediation write identity. Set this as the
    AZURE_REMEDIATION_WRITE_CLIENT_ID environment variable on the Rapticore side and as
    CloudCapabilityGrant.credentialClientId. It is intentionally different from the
    scanner client id. Null when enable_remediation_write = false.
  EOT
  value       = one(azurerm_user_assigned_identity.remediation_write[*].client_id)
}

output "remediation_write_principal_id" {
  description = <<-EOT
    Object (principal) id of the remediation write identity's service principal. Maps to
    CloudCapabilityGrant.providerPrincipalId. Null when enable_remediation_write = false.
  EOT
  value       = one(azurerm_user_assigned_identity.remediation_write[*].principal_id)
}

output "remediation_write_identity_resource_id" {
  description = "Full ARM resource id of the remediation write user-assigned identity. Null when disabled."
  value       = one(azurerm_user_assigned_identity.remediation_write[*].id)
}

output "remediation_write_role_definition_id" {
  description = "Resource id of the least-privilege custom remediation write role. Null when disabled."
  value       = one(azurerm_role_definition.remediation_write[*].role_definition_resource_id)
}

output "remediation_write_scope" {
  description = <<-EOT
    ARM scope the write role is assigned at. Use this as selectedScopes on each
    azure.direct-remediation/<actionId> capability grant.
  EOT
  value       = var.role_scope
}

output "remediation_write_federated_audience" {
  description = "Audience configured on the write identity's federated credential (mirrors the scanner's audience)."
  value       = var.federated_credential_audience
}
