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

variable "admin_db_url" {
  type        = string
  description = "Full admin DB DSN. Used only when admin_db_mode = byo."
  default     = ""
}

variable "db_sku" {
  type        = string
  description = "Postgres Flexible Server SKU (provision-pg mode)."
  default     = "GP_Standard_D2s_v3"
}

variable "db_storage_gb" {
  type        = number
  description = "Postgres Flexible Server storage in GiB (provision-pg mode)."
  default     = 131072 # 128 GiB, the smallest Flexible Server storage tier
}

variable "db_username" {
  type        = string
  description = "Postgres Flexible Server admin username (provision-pg mode)."
  default     = "mountos"
}

variable "vault_hosting" {
  type        = string
  description = "Vault hosting: self-hosted (provision a VM Vault) | managed-byo (use vault_addr)."
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
  description = "appserv AppRole secret_id (short-TTL; prefer Key Vault/wrapped in real use)."
  sensitive   = true
  default     = ""
}

variable "vault_vm_size" {
  type        = string
  description = "Azure VM size for the self-hosted Vault node (arm64)."
  default     = "Standard_D2ps_v5"
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

locals {
  provision_pg   = var.admin_db_mode == "provision-pg"
  self_vault     = var.vault_hosting == "self-hosted"
  vault_endpoint = local.self_vault ? "https://${azurerm_network_interface.vault[0].private_ip_address}:8200" : var.vault_addr
}
