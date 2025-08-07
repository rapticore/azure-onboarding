terraform {
  backend "azurerm" {
    resource_group_name  = "rapticore-test-rg"
    storage_account_name = "rapticorerttmtfstate"
    container_name       = "rapticorerttmtfstatecontainer"
    key                  = "onboarding.terraform.tfstate"
  }
}
