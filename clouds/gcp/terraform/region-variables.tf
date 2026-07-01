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

variable "region_db_url" {
  type        = string
  description = "Full region DB DSN. Used only when region_db_mode = byo."
  default     = ""
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

variable "region_vault_hosting" {
  type        = string
  description = "Region Vault hosting: self-hosted (provision a GCE Vault) | managed-byo (use region_vault_addr)."
  default     = "self-hosted"
  validation {
    condition     = contains(["self-hosted", "managed-byo"], var.region_vault_hosting)
    error_message = "region_vault_hosting must be self-hosted or managed-byo."
  }
}

variable "region_vault_addr" {
  type        = string
  description = "External region Vault address. Used only when region_vault_hosting = managed-byo."
  default     = ""
}

variable "region_vault_role_id" {
  type        = string
  description = "dataserv AppRole role_id for the region Vault (from the region seed step)."
  default     = ""
}

variable "region_vault_secret_id" {
  type        = string
  description = "dataserv AppRole secret_id for the region Vault (short-TTL; prefer Secret Manager/wrapped in real use)."
  sensitive   = true
  default     = ""
}

variable "region_vault_machine_type" {
  type        = string
  description = "GCE machine type for the self-hosted region Vault node (arm64)."
  default     = "t2a-standard-2"
}

locals {
  region_provision_sql  = var.region_db_mode == "provision-sql"
  region_self_vault     = var.region_vault_hosting == "self-hosted"
  region_vault_endpoint = local.region_self_vault ? "https://${google_compute_instance.region_vault[0].network_interface[0].network_ip}:8200" : var.region_vault_addr
}
