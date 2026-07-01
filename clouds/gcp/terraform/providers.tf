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
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project     = "mountos"
    managed-by  = "terraform"
    environment = var.mode
  }
}
