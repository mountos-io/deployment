# Hub vars. Mirrors clouds/aws/terraform/variables.tf; Azure-specific naming
# (Dpsv5 = the Ampere Altra ARM VM family, sized close to the AWS Graviton /
# GCP Tau T2A defaults, not an exact match).

variable "mode" {
  type        = string
  description = "Deployment mode. production enables HA-leaning defaults."
  default     = "production"
  validation {
    condition     = contains(["production", "non-production"], var.mode)
    error_message = "mode must be production or non-production."
  }
}

# Azure VMs require either an SSH key or password auth (unlike AWS/GCP, where
# key-pair-less/password-less boot via the platform's own agent is normal) —
# REQUIRED, no default. Login is otherwise via the managed identity only; this
# key is for operator break-glass access, not part of the boot/config flow.
variable "admin_ssh_public_key" {
  type        = string
  description = "SSH public key for operator access to VMs (required by Azure; not used by the boot/config flow itself)."
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
  description = "Desired/min/max appserv instances in the VMSS."
  default     = 2
}

variable "appserv_vm_size" {
  type        = string
  description = "Azure VM size for appserv (Dpsv5, arm64)."
  default     = "Standard_D2ps_v5"
}

variable "admin_db_mode" {
  type        = string
  description = "Admin DB provisioning mode: provision-pg | byo."
  default     = "provision-pg"
  validation {
    condition     = contains(["provision-pg", "byo"], var.admin_db_mode)
    error_message = "admin_db_mode must be provision-pg or byo."
  }
}

variable "admin_db_provider_version" {
  type        = string
  description = "Admin DB engine major version (PostgreSQL)."
  default     = "18"
}

variable "db_sku" {
  type        = string
  description = "Postgres Flexible Server SKU (provision-pg mode)."
  default     = "GP_Standard_D2s_v3"
}

variable "db_storage_gb" {
  type        = number
  description = "Postgres Flexible Server storage in GiB (provision-pg mode)."
  default     = 128 # must map to a Flexible Server storage tier (32, 64, 128, ...)
}

variable "db_username" {
  type        = string
  description = "Postgres Flexible Server admin username (provision-pg mode)."
  default     = "mountos"
}

# Secret store. This package NEVER installs or launches HashiCorp Vault (BSL:
# packaging a product so Vault must be downloaded for it to operate is
# "embedded" use). Two supported providers:
#   azure (RECOMMENDED)  cloud-native Azure Key Vault — platform-managed HA,
#                        managed-identity auth, no AppRole/CA machinery; the
#                        seed scripts write the initial mountos--* secrets.
#   hashicorp (byo)      the operator brings a Vault (HCP Vault Dedicated or
#                        their own cluster) and supplies vault_addr; the seed
#                        scripts only create mounts/policies/AppRole/values.
variable "vault_provider" {
  type        = string
  description = "Secret store: azure (cloud-native Key Vault, RECOMMENDED) | hashicorp (byo Vault via vault_addr; never launched by this package)."
  default     = "azure"
  validation {
    condition     = contains(["azure", "hashicorp"], var.vault_provider)
    error_message = "vault_provider must be azure or hashicorp."
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
  description = "CA certificate PEM for a byo Vault that serves a PRIVATE CA. Published to the hub Key Vault so instances trust it. Leave empty when the byo Vault has a publicly-trusted certificate (system CAs are used)."
  default     = ""
}

variable "vault_role_id" {
  type        = string
  description = "appserv AppRole role_id (from `make bootstrap`). hashicorp provider only."
  default     = ""
}

variable "vault_secret_id" {
  type        = string
  description = "appserv AppRole secret_id (short-TTL; prefer Key Vault/wrapped in real use). hashicorp provider only."
  sensitive   = true
  default     = ""
}

variable "alarm_email" {
  type        = string
  description = "Email for alert notifications; empty disables the action group."
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

variable "dns_zone_name" {
  type        = string
  description = "Existing Azure DNS zone name for hub_domain. Empty skips DNS."
  default     = ""
}

variable "dns_zone_resource_group" {
  type        = string
  description = "Resource group containing dns_zone_name. Required when dns_zone_name is set."
  default     = ""
}

variable "hub_certificate_secret_id" {
  type        = string
  description = "Existing Key Vault certificate secret id for the App Gateway HTTPS listener. REQUIRED — Azure has no zero-touch DNS-validated managed-cert primitive like AWS ACM or Google-managed certs; the operator must bring their own certificate (issue via Key Vault's integrated CA, Let's Encrypt, or import an existing one)."
  default     = ""
}

variable "resource_prefix" {
  type        = string
  description = "Optional resource-namespace prefix (1-11 lowercase alphanumeric/hyphen chars). Set when this Azure subscription already hosts another mountOS deployment, so secret names and provisioned resource names don't collide. Must match the VAULT_RESOURCE_PREFIX env var used by every service in this deployment. The Key Vault names use only the first 3 characters of this value (Azure's 24-char Key Vault name cap), see key-vaults.tf."
  default     = ""
  validation {
    condition     = var.resource_prefix == "" || can(regex("^[a-z0-9]([a-z0-9-]{0,9}[a-z0-9])?$", var.resource_prefix))
    error_message = "resource_prefix must be empty or 1-11 lowercase alphanumeric/hyphen characters, not starting or ending with a hyphen (kept in sync with the tighter AWS ALB/NLB 32-char name cap)."
  }
}

locals {
  provision_pg  = var.admin_db_mode == "provision-pg"
  hub_hashicorp = var.vault_provider == "hashicorp"
  name_root     = var.resource_prefix != "" ? "mountos-${var.resource_prefix}" : "mountos"
  # kv: instances fetch the byo Vault's private CA from the hub Key Vault
  # (published by Terraform from vault_ca_pem). system: byo Vault with a
  # publicly-trusted cert — no CA fetch, no VAULT_CACERT. Unused by the azure
  # provider.
  hub_vault_ca_source = var.vault_ca_pem != "" ? "kv" : "system"
  # No DB DSN is EVER a Terraform value. provision-pg: seed-vault.sh gets
  # ADMIN_DB_URL built from admin_db_host + the Key Vault password secret
  # (admin_db_secret_id output; the password itself is still in tfstate via
  # random_password — see rds.tf's PARITY GAP note). byo: the operator sets
  # ADMIN_DB_URL in answers.env for the seed step — Terraform neither needs
  # nor stores it.
}
