# Hub vars. Mirrors clouds/aws/terraform/variables.tf; GCP-specific naming
# (machine types are Tau T2A — the ARM family — sized as close to the AWS
# Graviton defaults as GCP's shapes allow, not an exact match).

variable "mode" {
  type        = string
  description = "Deployment mode. production enables HA-leaning defaults."
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
    condition     = length(var.hub_domain) > 0 && !can(regex("(^|\\.)(example|changeme|replace|your-domain)(\\.|$)", lower(var.hub_domain)))
    error_message = "Set hub_domain to your real public FQDN (placeholders like example/changeme/replace are rejected)."
  }
}

variable "appserv_count" {
  type        = number
  description = "Desired/min/max appserv instances in the MIG."
  default     = 2
}

variable "appserv_machine_type" {
  type        = string
  description = "GCE machine type for appserv (Tau T2A, arm64)."
  default     = "t2a-standard-2"
}

variable "admin_db_mode" {
  type        = string
  description = "Admin DB provisioning mode: provision-sql | byo."
  default     = "provision-sql"
  validation {
    condition     = contains(["provision-sql", "byo"], var.admin_db_mode)
    error_message = "admin_db_mode must be provision-sql or byo."
  }
}

variable "admin_db_provider_version" {
  type        = string
  description = "Admin DB engine major version (PostgreSQL)."
  default     = "POSTGRES_18"
}

variable "admin_db_url" {
  type        = string
  description = "Full admin DB DSN. Used only when admin_db_mode = byo."
  default     = ""
}

variable "db_tier" {
  type        = string
  description = "Cloud SQL machine tier (provision-sql mode)."
  default     = "db-custom-2-8192"
}

variable "db_disk_gb" {
  type        = number
  description = "Cloud SQL disk size in GiB (provision-sql mode)."
  default     = 100
}

variable "db_username" {
  type        = string
  description = "Cloud SQL master username (provision-sql mode)."
  default     = "mountos"
}

variable "vault_hosting" {
  type        = string
  description = "Vault hosting: self-hosted (provision a GCE Vault) | managed-byo (use vault_addr)."
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
  description = "appserv AppRole secret_id (short-TTL; prefer Secret Manager/wrapped in real use)."
  sensitive   = true
  default     = ""
}

variable "vault_machine_type" {
  type        = string
  description = "GCE machine type for the self-hosted Vault node (arm64)."
  default     = "t2a-standard-2"
}

variable "alarm_email" {
  type        = string
  description = "Email for alert notifications; empty disables the notification channel."
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
  description = "Existing Cloud DNS managed zone name for hub_domain. Empty skips DNS + the managed cert."
  default     = ""
}

variable "hub_certificate_id" {
  type        = string
  description = "Existing google_compute_ssl_certificate/certificate-manager cert id, used when dns_zone_name is empty."
  default     = ""
}

locals {
  provision_sql  = var.admin_db_mode == "provision-sql"
  self_vault     = var.vault_hosting == "self-hosted"
  vault_endpoint = local.self_vault ? "https://${google_compute_instance.vault[0].network_interface[0].network_ip}:8200" : var.vault_addr
}
