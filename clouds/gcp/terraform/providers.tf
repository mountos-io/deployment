terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "project_id" {
  type        = string
  description = "GCP project id. Required — the operator's own project, not created here."
}

variable "region" {
  type        = string
  description = "GCP region."
  default     = "us-central1"

  # The value is interpolated into root shell scripts at first boot.
  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.region))
    error_message = "region must be 3 to 30 lower-case letters, digits or hyphens."
  }
}

variable "deployment_id" {
  type        = string
  description = "Stable identifier for this logical deployment (a UUID), set on every resource as the label mountos_deployment_id so a hub can be found again by a label query instead of only by local Terraform state. Empty (default) omits it."
  default     = ""
}

variable "managed_by" {
  type        = string
  description = "What drove this apply: \"terraform\" (a manual or CI apply) or a tool name such as \"mountos-launcher\". Set as the label mountos_managed_by."
  default     = "terraform"
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = merge(
    {
      project            = "mountos"
      managed-by         = "terraform"
      environment        = var.mode
      mountos_role       = "hub"
      mountos_managed_by = var.managed_by
    },
    var.deployment_id != "" ? { mountos_deployment_id = var.deployment_id } : {},
  )
}
