output "identity_client_id" {
  value = azurerm_user_assigned_identity.rapticore.client_id
}

output "identity_principal_id" {
  value = azurerm_user_assigned_identity.rapticore.principal_id
}

output "identity_resource_id" {
  value = azurerm_user_assigned_identity.rapticore.id
}

# Which Rapticore tenants this identity currently trusts. Handy for verifying an
# additional tenant landed without having to read the portal.
output "federated_credential_subjects" {
  description = "Map of federated credential name -> token subject configured on the scanning identity."
  value       = { for k, c in azurerm_federated_identity_credential.rapticore_oidc : c.name => c.subject }
}
