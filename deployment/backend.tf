# Remote state backend for the onboarding deployment.
#
# Terraform/OpenTofu backend blocks cannot reference variables, so these values
# must be filled in by hand before `tofu init`. Take them from the outputs of the
# bootstrap-tfstate step, which creates the storage account and container that
# hold this state. Replace the three placeholders below with your own values.
terraform {
  backend "azurerm" {
    resource_group_name  = "<your-tfstate-resource-group>"  # bootstrap-tfstate output: resource_group_name
    storage_account_name = "<your-tfstate-storage-account>" # bootstrap-tfstate output: storage_account_name
    container_name       = "<your-tfstate-container>"       # bootstrap-tfstate output: container_name
    key                  = "onboarding.terraform.tfstate"
  }
}
