terraform {
  backend "azurerm" {
    resource_group_name  = "rapticore-rttm-rg-WUS2"
    storage_account_name = "rapticoretfstate"
    container_name       = "rapticoretfstatecontainer"
    key                  = "onboarding.terraform.tfstate"
  }
}
