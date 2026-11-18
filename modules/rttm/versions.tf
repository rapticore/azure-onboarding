terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # The module uses azurerm 3.x arguments (diagnostic settings, function app, security center automation); 4.x
      # renamed several of them, and an unpinned module resolved to 4.x and failed `terraform validate`. Same range as
      # deployment/main.tf.
      version = ">= 3.95, < 4.0"
    }
  }
}
