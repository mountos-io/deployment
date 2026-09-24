terraform {
  # >= 1.11 for write-only arguments (rds.tf's password_wo/secret_string_wo,
  # feeding the non-production admin DB password from an ephemeral resource
  # without ever writing it to tfstate). Ephemeral resources alone need only
  # >= 1.10, but write-only arguments are the stricter requirement here.
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "deployment_id" {
  type        = string
  description = "Stable identifier for this logical deployment (e.g. a UUID), tagged onto every resource as mountos:deployment-id so a hub can be rediscovered by an AWS-wide tag query (Resource Groups Tagging API) rather than only by local Terraform state. Generate once and keep it stable across re-applies. Empty (default) omits the tag."
  default     = ""
}

variable "managed_by" {
  type        = string
  description = "Tag value (mountos:managed-by) identifying what drove this apply: \"terraform\" (default, a manual/CI apply) vs a tool name like \"mountos-launcher\" or a test-run label like \"mountos-launcher-test\". Lets a launcher (or an operator) distinguish its own deployments from others sharing the same account."
  default     = "terraform"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        Project              = "mountOS"
        ManagedBy            = "terraform"
        Environment          = var.mode
        "mountos:role"       = "hub"
        "mountos:managed-by" = var.managed_by
      },
      var.deployment_id != "" ? { "mountos:deployment-id" = var.deployment_id } : {},
    )
  }
}
