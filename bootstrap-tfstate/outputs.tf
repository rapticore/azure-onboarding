output "storage_account_name" {
  value       = azurerm_storage_account.tfstate.name
  description = "Name of the storage account used for Terraform state"
}

output "container_name" {
  value       = azurerm_storage_container.tfstate.name
  description = "Name of the container used for Terraform state"
}

output "resource_group_name" {
  value       = var.resource_group_name
  description = "Resource group in which the storage account is created"
}
