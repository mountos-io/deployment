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

  # The value is interpolated into root shell scripts at first boot.
  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.region))
    error_message = "region must be 3 to 30 lower-case letters, digits or hyphens."
  }
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

variable "deployment_id" {
  type        = string
  description = "Stable identifier for this logical deployment (a UUID), set on every resource as the tag mountos:deployment-id so a hub can be found again by a resource group tag query instead of only by local Terraform state. Empty (default) omits it."
  default     = ""
}

variable "managed_by" {
  type        = string
  description = "What drove this apply: \"terraform\" (a manual or CI apply) or a tool name such as \"mountos-launcher\". Set as the tag mountos:managed-by."
  default     = "terraform"
}

# Azure has no AWS-account/GCP-project equivalent inside the module — every
# resource lives in an explicit resource group, unlike AWS/GCP where the
# account/project is ambient. One resource group holds the whole deployment.
resource "azurerm_resource_group" "main" {
  name     = local.name_root
  location = var.region
  tags = merge(
    {
      project              = local.name_root
      managed-by           = "terraform"
      environment          = var.mode
      "mountos:role"       = "hub"
      "mountos:managed-by" = var.managed_by
    },
    var.deployment_id != "" ? { "mountos:deployment-id" = var.deployment_id } : {},
  )
}
