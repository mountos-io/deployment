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

# Secret store. This package NEVER installs or launches HashiCorp Vault (BSL:
# packaging a product so Vault must be downloaded for it to operate is
# "embedded" use). Two supported providers:
#   gcp (RECOMMENDED)  cloud-native Secret Manager — platform-managed HA,
#                      instance service-account auth (Application Default
#                      Credentials), no AppRole/CA machinery; the seed scripts
#                      write the initial mountos__* secrets.
#   hashicorp (byo)    the operator brings a Vault (HCP Vault Dedicated or
#                      their own cluster) and supplies vault_addr; the seed
#                      scripts only create mounts/policies/AppRole/values.
variable "vault_provider" {
  type        = string
  description = "Secret store: gcp (cloud-native Secret Manager, RECOMMENDED) | hashicorp (byo Vault via vault_addr; never launched by this package)."
  default     = "gcp"
  validation {
    condition     = contains(["gcp", "hashicorp"], var.vault_provider)
    error_message = "vault_provider must be gcp or hashicorp."
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
  description = "CA certificate PEM for a byo Vault that serves a PRIVATE CA. Published to Secret Manager so instances trust it. Leave empty when the byo Vault has a publicly-trusted certificate (system CAs are used)."
  default     = ""
}

variable "vault_role_id" {
  type        = string
  description = "appserv AppRole role_id (from `make bootstrap`). hashicorp provider only."
  default     = ""
}

variable "vault_secret_id" {
  type        = string
  description = "appserv AppRole secret_id (short-TTL; prefer Secret Manager/wrapped in real use). hashicorp provider only."
  sensitive   = true
  default     = ""
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

variable "resource_prefix" {
  type        = string
  description = "Optional resource-namespace prefix (1-11 lowercase alphanumeric/hyphen chars). Set when this GCP project already hosts another mountOS deployment, so secret paths and provisioned resource names don't collide. Must match the VAULT_RESOURCE_PREFIX env var used by every service in this deployment."
  default     = ""
  validation {
    condition     = var.resource_prefix == "" || can(regex("^[a-z0-9]([a-z0-9-]{0,9}[a-z0-9])?$", var.resource_prefix))
    error_message = "resource_prefix must be empty or 1-11 lowercase alphanumeric/hyphen characters, not starting or ending with a hyphen (kept in sync with the tighter AWS ALB/NLB 32-char name cap, even though GCP's own service-account account_id budget alone would allow 12)."
  }
}

locals {
  provision_sql = var.admin_db_mode == "provision-sql"
  hub_gcp       = var.vault_provider == "gcp"
  hub_hashicorp = var.vault_provider == "hashicorp"
  # GCP secret/resource root, mirrors the Go GCP secrets encoder's nameRoot().
  name_root = var.resource_prefix != "" ? "mountos-${var.resource_prefix}" : "mountos"
  # role_id syntax is [a-zA-Z0-9_.]+ only (no dashes) — used only where a dash
  # can't appear (google_project_iam_custom_role.role_id in region-iam.tf).
  name_root_camel = var.resource_prefix != "" ? title(replace(var.resource_prefix, "-", "")) : ""
  # secret: instances fetch the byo Vault's private CA from Secret Manager
  # (published by Terraform from vault_ca_pem). system: byo Vault with a
  # publicly-trusted cert — no CA fetch, no VAULT_CACERT. Unused by the gcp
  # provider.
  hub_vault_ca_source = var.vault_ca_pem != "" ? "secret" : "system"
  # No DB DSN is EVER a Terraform value in byo mode: the operator sets
  # ADMIN_DB_URL in answers.env for the seed step — Terraform neither needs nor
  # stores it. provision-sql: build the DSN from admin_db_host + the
  # mountos-admin-db-password secret (see outputs.tf).
}
