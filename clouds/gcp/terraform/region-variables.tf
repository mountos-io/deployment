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

# DB_MAX_OPEN_CONNS overrides for the co-located dataserv/gcserv pair. Empty
# (default) leaves them unset so the binary sizes its own pool — do NOT set
# these deployment-wide without measuring: the code's default is
# min(max(8*vCPU, 50), 200), which is right for a large node.
#
# DIALECT-SENSITIVE — these are single-primary (PostgreSQL/MySQL) numbers.
# A DISTRIBUTED engine (CockroachDB, YugabyteDB, TiDB) fronts a cluster rather
# than one primary: connections spread across nodes, idle ones cost far less,
# and the binary deliberately scales its own baseline 4x for that case. Pinning
# a single-primary value here would CAP a distributed deployment well below
# what it wants. Leave empty unless you know the target engine is a single
# primary and you have measured it.
#
# They matter on SMALL nodes, where that formula's 50-connection FLOOR does all
# the work: a 2-vCPU box computes 8*2=16 and gets floored to 50, the same pool
# a 6-vCPU box would get. dataserv and gcserv each hold their OWN pool against
# the same regional DB, so a 3-node region is 6 pools; add appserv's pool
# against the shared admin DB and a small managed instance is near its
# max_connections ceiling before real load.
#
# Splitting them (rather than one shared value) lets the hot metadata path keep
# the larger share while background GC takes less. gcserv's value is written to
# a SECOND env file, gcserv.env, listed after dataserv.env in its unit. It is
# deliberately NOT a systemd Environment= line: systemd.exec specifies that
# EnvironmentFile= overrides Environment= regardless of line order, so an
# Environment= override of a key dataserv.env also sets is silently discarded.
# Later EnvironmentFile= entries DO override earlier ones.
variable "dataserv_db_max_open_conns" {
  type        = string
  description = "DB_MAX_OPEN_CONNS for dataserv. Empty = let the binary size its own pool (min(max(8*vCPU,50),200))."
  default     = ""
}

variable "gcserv_db_max_open_conns" {
  type        = string
  description = "DB_MAX_OPEN_CONNS for co-located gcserv, written to gcserv.env which its unit reads after dataserv.env. Empty = gcserv INHERITS dataserv_db_max_open_conns through the shared env file, and only falls back to sizing its own pool when that is empty too. Values below DB_POOL_MIN_CONNS (2) are silently auto-upgraded by warmPoolConnections."
  default     = ""
}
