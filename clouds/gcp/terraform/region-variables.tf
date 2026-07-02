# Region (dataserv + co-located gcserv) vars. Mirrors clouds/aws/terraform/region-variables.tf.

variable "region_cluster_id" {
  type        = string
  description = "Cluster UUID this region belongs to. Created on the HUB via the Admin SDK after the hub is up; supplied here after the provision step."
}

variable "dataserv_count" {
  type        = number
  description = "Desired/min/max dataserv instances in the MIG (1 per zone for raft quorum)."
  default     = 3
}

variable "dataserv_machine_type" {
  type        = string
  description = "GCE machine type for dataserv (Tau T2A, arm64)."
  default     = "t2a-standard-8"
}

variable "arena_size" {
  type        = string
  description = "METAENGINE_ARENA_SIZE unit string. Size to the metadata working set, ~5M files/GiB; prod is much larger."
  default     = "1GB"
}

variable "raft_disk_gb" {
  type        = number
  description = "Raft data dir disk size (GiB) at /mnt/raft. Ephemeral per instance; quorum re-syncs on replacement."
  default     = 100
}

variable "gcserv_colocated" {
  type        = bool
  description = "Run gcserv as a second systemd unit on each dataserv instance."
  default     = true
}

variable "region_db_mode" {
  type        = string
  description = "Region DB provisioning mode: provision-sql | byo."
  default     = "provision-sql"
  validation {
    condition     = contains(["provision-sql", "byo"], var.region_db_mode)
    error_message = "region_db_mode must be provision-sql or byo."
  }
}

variable "region_db_tier" {
  type        = string
  description = "Region Cloud SQL machine tier (provision-sql mode)."
  default     = "db-custom-2-8192"
}

variable "region_db_disk_gb" {
  type        = number
  description = "Region Cloud SQL disk size in GiB (provision-sql mode)."
  default     = 100
}

variable "region_db_username" {
  type        = string
  description = "Region Cloud SQL master username (provision-sql mode)."
  default     = "mountos"
}

variable "region_db_provider_version" {
  type        = string
  description = "Region Cloud SQL engine major version (PostgreSQL; decoupled from the hub DB)."
  default     = "POSTGRES_18"
}

# Region secret store; same model as the hub's (see variables.tf): gcp =
# cloud-native Secret Manager (RECOMMENDED; hub + region share the project's
# mountos__* namespace, isolated by IAM), hashicorp = byo Vault, never launched.
variable "region_vault_provider" {
  type        = string
  description = "Region secret store: gcp (cloud-native Secret Manager, RECOMMENDED) | hashicorp (byo Vault via region_vault_addr; never launched by this package)."
  default     = "gcp"
  validation {
    condition     = contains(["gcp", "hashicorp"], var.region_vault_provider)
    error_message = "region_vault_provider must be gcp or hashicorp."
  }
}

variable "region_vault_addr" {
  type        = string
  description = "byo region Vault address (https://...). Required when region_vault_provider = hashicorp."
  default     = ""
  validation {
    condition     = var.region_vault_addr == "" || startswith(var.region_vault_addr, "https://")
    error_message = "region_vault_addr must be an https:// URL — region services send AppRole credentials to it."
  }
}

variable "region_vault_ca_pem" {
  type        = string
  description = "CA certificate PEM for a byo region Vault that serves a PRIVATE CA. Published to Secret Manager so instances trust it. Leave empty when the byo Vault has a publicly-trusted certificate."
  default     = ""
}

variable "region_vault_role_id" {
  type        = string
  description = "dataserv AppRole role_id for the byo region Vault (from the region seed step). hashicorp provider only."
  default     = ""
}

variable "region_vault_secret_id" {
  type        = string
  description = "dataserv AppRole secret_id for the byo region Vault (short-TTL; prefer Secret Manager/wrapped in real use). hashicorp provider only."
  sensitive   = true
  default     = ""
}

locals {
  region_provision_sql = var.region_db_mode == "provision-sql"
  region_gcp           = var.region_vault_provider == "gcp"
  region_hashicorp     = var.region_vault_provider == "hashicorp"
  # See variables.tf's hub_vault_ca_source for the secret|system semantics.
  region_vault_ca_source = var.region_vault_ca_pem != "" ? "secret" : "system"
  # No DB DSN is EVER a Terraform value in byo mode: the operator sets
  # REGION_DB_URL in the region-seed environment. provision-sql: build the DSN
  # from region_db_host + the mountos-region-db-password secret (see
  # region-outputs.tf).
}
