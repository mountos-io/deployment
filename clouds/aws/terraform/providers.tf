terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "mountOS"
      ManagedBy   = "terraform"
      Environment = var.mode
    }
  }
}
