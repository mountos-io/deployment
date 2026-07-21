terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "region" {
  type        = string
  description = "Azure region."
  default     = "eastus"
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

# Azure has no AWS-account/GCP-project equivalent inside the module — every
# resource lives in an explicit resource group, unlike AWS/GCP where the
# account/project is ambient. One resource group holds the whole deployment.
resource "azurerm_resource_group" "main" {
  name     = local.name_root
  location = var.region
  tags = {
    project     = local.name_root
    managed-by  = "terraform"
    environment = var.mode
  }
}
