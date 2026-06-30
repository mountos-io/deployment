# New init-hub vars. region lives in providers.tf;
# vpc_cidr/enable_nat in network.tf; client_cidr in security-groups.tf.

variable "mode" {
  type        = string
  description = "Deployment mode. production enables multi-AZ RDS and HA-leaning defaults."
  default     = "production"
  validation {
    condition     = contains(["production", "non-production"], var.mode)
    error_message = "mode must be production or non-production."
  }
}

variable "hub_domain" {
  type        = string
  description = "Public hub FQDN (e.g. hub.acme.com). REQUIRED — clients reach https://<hub_domain>."
  validation {
    condition     = length(var.hub_domain) > 0 && !can(regex("example|changeme|replace|your-domain", lower(var.hub_domain)))
    error_message = "Set hub_domain to your real public FQDN (placeholders like example/changeme/replace are rejected)."
  }
}

variable "appserv_count" {
  type        = number
  description = "Desired/min/max appserv instances in the ASG."
  default     = 2
}

variable "appserv_instance_type" {
  type        = string
  description = "EC2 instance type for appserv (arm64)."
  default     = "m7g.large"
}

variable "admin_db_mode" {
  type        = string
  description = "Admin DB provisioning mode: provision-rds | byo."
  default     = "provision-rds"
  validation {
    condition     = contains(["provision-rds", "byo"], var.admin_db_mode)
    error_message = "admin_db_mode must be provision-rds or byo."
  }
}

variable "admin_db_provider_version" {
  type        = string
  description = "Admin DB engine major version (PostgreSQL)."
  default     = "18"
}

variable "admin_db_url" {
  type        = string
  description = "Full admin DB DSN. Used only when admin_db_mode = byo."
  default     = ""
}

variable "db_instance_class" {
  type        = string
  description = "RDS instance class (provision-rds mode)."
  default     = "db.m7g.large"
}

variable "db_allocated_gb" {
  type        = number
  description = "RDS allocated storage in GiB (provision-rds mode)."
  default     = 100
}

variable "db_username" {
  type        = string
  description = "RDS master username (provision-rds mode)."
  default     = "mountos"
}

variable "db_password" {
  type        = string
  description = "RDS master password (provision-rds mode)."
  sensitive   = true
  default     = ""
}

variable "vault_hosting" {
  type        = string
  description = "Vault hosting: self-hosted (provision an EC2 Vault) | managed-byo (use vault_addr)."
  default     = "self-hosted"
  validation {
    condition     = contains(["self-hosted", "managed-byo"], var.vault_hosting)
    error_message = "vault_hosting must be self-hosted or managed-byo."
  }
}

variable "vault_addr" {
  type        = string
  description = "External Vault address. Used only when vault_hosting = managed-byo."
  default     = ""
}

variable "vault_role_id" {
  type        = string
  description = "appserv AppRole role_id (from `make bootstrap`)."
  default     = ""
}

variable "vault_secret_id" {
  type        = string
  description = "appserv AppRole secret_id (short-TTL; prefer SSM/wrapped in real use)."
  sensitive   = true
  default     = ""
}

variable "vault_instance_type" {
  type        = string
  description = "EC2 instance type for the self-hosted Vault node (arm64)."
  default     = "t4g.medium"
}

variable "alarm_email" {
  type        = string
  description = "Email for CloudWatch alarm notifications; empty disables the SNS subscription"
  default     = ""
}

variable "mos_version" {
  type        = string
  description = "mountOS package version to install. Empty installs latest."
  default     = ""
}

variable "mos_installer_sha256" {
  type        = string
  description = "Optional sha256 of the n.sh installer script; when set, cloud-init verifies before executing."
  default     = ""
}

variable "route53_zone_id" {
  type        = string
  description = "Existing Route53 hosted zone for hub_domain. Empty skips DNS + ACM."
  default     = ""
}

variable "hub_certificate_arn" {
  type        = string
  description = "ACM cert ARN for the hub ALB when not using route53_zone_id"
  default     = ""
}

locals {
  provision_rds  = var.admin_db_mode == "provision-rds"
  self_vault     = var.vault_hosting == "self-hosted"
  vault_endpoint = local.self_vault ? "https://${aws_instance.vault[0].private_ip}:8200" : var.vault_addr
  admin_dsn      = local.provision_rds ? "postgresql://${var.db_username}:${var.db_password}@${aws_db_instance.admin[0].endpoint}/mountos_admin?sslmode=require" : var.admin_db_url
}
