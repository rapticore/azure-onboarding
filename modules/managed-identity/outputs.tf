output "identity_client_id" {
  value = azurerm_user_assigned_identity.rapticore.client_id
}

output "identity_principal_id" {
  value = azurerm_user_assigned_identity.rapticore.principal_id
}

output "identity_resource_id" {
  value = azurerm_user_assigned_identity.rapticore.id
}
