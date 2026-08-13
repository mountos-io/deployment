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

variable "resource_prefix" {
  type        = string
  description = "Optional resource-namespace prefix (1-11 lowercase alphanumeric/hyphen chars). Set when this AWS account/region already hosts another mountOS deployment, so secret paths and provisioned resource names don't collide. Must match the VAULT_RESOURCE_PREFIX env var used by every service in this deployment."
  default     = ""
  validation {
    condition     = var.resource_prefix == "" || can(regex("^[a-z0-9]([a-z0-9-]{0,9}[a-z0-9])?$", var.resource_prefix))
    error_message = "resource_prefix must be empty or 1-11 lowercase alphanumeric/hyphen characters, not starting or ending with a hyphen (bounded by the AWS ALB/NLB 32-char name cap)."
  }
}

variable "hub_domain" {
  type        = string
  description = "Public hub FQDN (e.g. hub.acme.com). REQUIRED — clients reach https://<hub_domain>."
  validation {
    condition     = length(var.hub_domain) > 0 && !can(regex("(^|\\.)(example|changeme|replace|your-domain)(\\.|$)", lower(var.hub_domain)))
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

# See region-variables.tf's dataserv/gcserv equivalents for the full rationale
# and the DIALECT-SENSITIVE warning (a distributed engine wants MORE, not less,
# so pinning a single-primary value here would cap it). Empty = let the binary
# size its own pool. Note appserv_count defaults to 2, so this value is held
# TWICE against the admin DB in a default deployment.
variable "appserv_db_max_open_conns" {
  type        = string
  description = "DB_MAX_OPEN_CONNS for appserv against the admin DB. Empty = let the binary size its own pool (min(max(8*vCPU,50),200), x4 if distributed)."
  default     = ""
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

# Secret store. This package NEVER installs or launches HashiCorp Vault (BSL:
# packaging a product so Vault must be downloaded for it to operate is
# "embedded" use). Two supported providers:
#   aws (RECOMMENDED)  cloud-native AWS Secrets Manager — platform-managed HA,
#                      instance-role auth, no AppRole/CA machinery; the seed
#                      scripts write the initial <name_root>/* secrets.
#   hashicorp (byo)    the operator brings a Vault (HCP Vault Dedicated or
#                      their own cluster) and supplies vault_addr; the seed
#                      scripts only create mounts/policies/AppRole/values.
variable "vault_provider" {
  type        = string
  description = "Secret store: aws (cloud-native Secrets Manager, RECOMMENDED) | hashicorp (byo Vault via vault_addr; never launched by this package)."
  default     = "aws"
  validation {
    condition     = contains(["aws", "hashicorp"], var.vault_provider)
    error_message = "vault_provider must be aws or hashicorp."
  }
}

variable "vault_addr" {
  type        = string
  description = "byo Vault address (https://...). Required when vault_provider = hashicorp."
  default     = ""
  validation {
    condition     = var.vault_addr == "" || startswith(var.vault_addr, "https://")
    error_message = "vault_addr must be an https:// URL — appserv sends AppRole credentials to it."
  }
}

variable "vault_ca_pem" {
  type        = string
  description = "CA certificate PEM for a byo Vault that serves a PRIVATE CA. Published to SSM so instances trust it. Leave empty when the byo Vault has a publicly-trusted certificate (system CAs are used)."
  default     = ""
}

variable "vault_role_id" {
  type        = string
  description = "appserv AppRole role_id (from `make bootstrap`). hashicorp provider only."
  default     = ""
}

variable "vault_secret_id" {
  type        = string
  description = "appserv AppRole secret_id (short-TTL; prefer SSM/wrapped in real use). hashicorp provider only."
  sensitive   = true
  default     = ""
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

# ---------- direct-IP appserv (small/single-instance deployments) ----------
# Default false: production keeps the ASG + ALB(443)/NLB(9443) path in compute.tf/lb.tf
# unchanged. true swaps to a single aws_instance with its own Elastic IP and Caddy
# terminating a real Let's Encrypt cert for hub_domain — no load balancer, no NAT,
# matching the direct-IP/custom-protocol pattern dataserv and blockserv already use.
# Trades the ALB's automatic stable-address-across-replacement property for cost;
# appropriate for appserv_count = 1 deployments (dev/demo/small), not multi-instance HA.
variable "appserv_direct_ip" {
  type        = bool
  description = "true: single direct-IP appserv instance + Elastic IP + Caddy, no ALB/NLB/NAT. false (default): the production ASG+ALB+NLB path."
  default     = false

  validation {
    condition     = !var.appserv_direct_ip || var.appserv_count == 1
    error_message = "appserv_direct_ip is a single-instance deployment shape — set appserv_count = 1."
  }
}

# ---------- admin dashboard (mountos-admin-client), optional ----------
# Default false: no admin instance, no cost, nothing changes for existing deployments.
variable "admin_client_enabled" {
  type        = bool
  description = "true: provision a small direct-IP instance running mountos-admin-client (own Elastic IP + Caddy for a real cert on admin_domain). false (default): not deployed."
  default     = false
}

variable "admin_domain" {
  type        = string
  description = "Public FQDN for the admin dashboard (e.g. admin.acme.com). REQUIRED when admin_client_enabled = true — separate domain from hub_domain, its own WebAuthn origin."
  default     = ""

  validation {
    condition     = !var.admin_client_enabled || (length(var.admin_domain) > 0 && !can(regex("(^|\\.)(example|changeme|replace|your-domain)(\\.|$)", lower(var.admin_domain))))
    error_message = "Set admin_domain to a real public FQDN when admin_client_enabled = true (placeholders like example/changeme/replace are rejected)."
  }
}

variable "admin_client_instance_type" {
  type        = string
  description = "EC2 instance type for the admin-client instance (arm64)."
  default     = "t4g.small"
}

# ---------- shared single-RDS mode (cost-saving, small deployments) ----------
# Default false: production keeps the hub admin DB and region DB fully separate
# (see rds.tf/region-rds.tf), matching mountOS's documented topology (one DB
# per region, decoupled from the hub). true opens the admin RDS's security
# group to dataserv so region_db_mode = byo can point REGION_DB_URL at the SAME
# instance (a different database on it) instead of provisioning a second RDS.
variable "share_admin_rds_with_region" {
  type        = bool
  description = "true: open the admin RDS's security group to dataserv, for region_db_mode = byo pointing REGION_DB_URL at the same instance (different database). false (default): no change to the admin RDS's security group."
  default     = false
}

locals {
  provision_rds = var.admin_db_mode == "provision-rds"
  hub_hashicorp = var.vault_provider == "hashicorp"
  # Root token for every provisioned resource name / secret path. Empty
  # resource_prefix keeps names byte-identical to the unprefixed default.
  name_root = var.resource_prefix != "" ? "mountos-${var.resource_prefix}" : "mountos"
  # ssm: instances fetch the byo Vault's private CA from SSM (published by
  # Terraform from vault_ca_pem). system: byo Vault with a publicly-trusted
  # cert — no CA fetch, no VAULT_CACERT. Unused by the aws provider.
  hub_vault_ca_source = var.vault_ca_pem != "" ? "ssm" : "system"
  # No DB DSN is EVER a Terraform value. provision-rds: AWS manages the master
  # password (Secrets Manager) and seed-vault.sh builds the DSN from
  # admin_db_host + admin_db_secret_arn. byo: the operator sets ADMIN_DB_URL in
  # answers.env for the seed step — Terraform neither needs nor stores it.
}
