# Region (dataserv + co-located gcserv) vars. Reuses hub vars (db_username,
# db_password, region, mos_version, mode) and hub resources (aws_kms_key.region,
# aws_security_group.dataserv/gcserv, data.aws_ami.al2023_arm64, aws_lb.appserv_srpc).

variable "region_cluster_id" {
  type        = string
  description = "Cluster UUID this region belongs to. Created on the HUB via the Admin SDK after the hub is up; supplied here after the provision step."
}

variable "dataserv_count" {
  type        = number
  description = "Desired/min/max dataserv instances in the ASG (1 per AZ for raft quorum)."
  default     = 3
}

variable "dataserv_instance_type" {
  type        = string
  description = "EC2 instance type for dataserv (arm64)."
  default     = "r7g.2xlarge"
}

variable "arena_size" {
  type        = string
  description = "METAENGINE_ARENA_SIZE unit string. Size to the metadata working set, ~5M files/GiB; prod is much larger."
  default     = "1GB"
}

# DB_MAX_OPEN_CONNS overrides for the co-located dataserv/gcserv pair. Empty
# (default) leaves them unset so the binary sizes its own pool — do NOT set
# these deployment-wide without measuring: the code's default is
# min(max(8*vCPU, 50), 200), which is right for a large node.
#
# DIALECT-SENSITIVE — these are single-primary (PostgreSQL/MySQL) numbers.
# A DISTRIBUTED engine (CockroachDB, YugabyteDB, TiDB) fronts a cluster rather
# than one primary: connections spread across nodes, idle ones cost far less,
# and the binary deliberately scales its own baseline 4x for that case
# (distributedConnScale in internal/db/connection.go). Pinning a
# single-primary value here would CAP a distributed deployment well below what
# it wants. Leave empty unless you know the target engine is a single primary
# and you have measured it.
#
# They matter on SMALL nodes, where that formula's 50-connection FLOOR does all
# the work: a 2-vCPU box computes 8*2=16 and gets floored to 50, the same pool
# a 6-vCPU box would get. dataserv and gcserv each hold their OWN pool against
# the same regional DB, so a 3-node region is 6 pools; add appserv's pool
# against the shared admin DB and a db.t4g.medium (max_connections=400, an
# AWS memory-derived default, not our setting) is at ~90% before real load.
#
# Splitting them (rather than one shared value) lets the hot metadata path keep
# the larger share while background GC takes less. Both are applied per-service
# even though the two share one env file — gcserv's is a systemd Environment=
# override, which wins over EnvironmentFile.
variable "dataserv_db_max_open_conns" {
  type        = string
  description = "DB_MAX_OPEN_CONNS for dataserv. Empty = let the binary size its own pool (min(max(8*vCPU,50),200))."
  default     = ""
}

variable "gcserv_db_max_open_conns" {
  type        = string
  description = "DB_MAX_OPEN_CONNS for co-located gcserv. Empty = let the binary size its own pool. Values below DB_POOL_MIN_CONNS (2) are silently auto-upgraded by warmPoolConnections."
  default     = ""
}

variable "raft_ebs_gb" {
  type        = number
  description = "Raft data dir EBS size (GiB) at /mnt/raft. Ephemeral per instance (delete_on_termination); quorum re-syncs on replacement."
  default     = 100
}

variable "raft_ebs_iops" {
  type        = number
  description = "Provisioned IOPS for the raft EBS volume (gp3)."
  default     = 3000
}

variable "gcserv_colocated" {
  type        = bool
  description = "Run gcserv as a second systemd unit on each dataserv instance."
  default     = true
}

variable "region_db_mode" {
  type        = string
  description = "Region DB provisioning mode: provision-rds | byo."
  default     = "provision-rds"
  validation {
    condition     = contains(["provision-rds", "byo"], var.region_db_mode)
    error_message = "region_db_mode must be provision-rds or byo."
  }
}

variable "region_db_username" {
  type        = string
  description = "Region RDS master username (provision-rds mode)."
  default     = "mountos"
}

variable "region_db_instance_class" {
  type        = string
  description = "Region RDS instance class (provision-rds mode)."
  default     = "db.m7g.large"
}

variable "region_db_allocated_gb" {
  type        = number
  description = "Region RDS allocated storage in GiB (provision-rds mode)."
  default     = 100
}

variable "region_db_provider_version" {
  type        = string
  description = "Region RDS engine major version (PostgreSQL; decoupled from the hub DB)."
  default     = "18"
}

# Region secret store; same model as the hub's (see variables.tf): aws =
# cloud-native Secrets Manager (RECOMMENDED; hub + region share the account's
# <name_root>/* namespace, isolated by IAM), hashicorp = byo Vault, never launched.
variable "region_vault_provider" {
  type        = string
  description = "Region secret store: aws (cloud-native Secrets Manager, RECOMMENDED) | hashicorp (byo Vault via region_vault_addr; never launched by this package)."
  default     = "aws"
  validation {
    condition     = contains(["aws", "hashicorp"], var.region_vault_provider)
    error_message = "region_vault_provider must be aws or hashicorp."
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
  description = "CA certificate PEM for a byo region Vault that serves a PRIVATE CA. Published to SSM so instances trust it. Leave empty when the byo Vault has a publicly-trusted certificate."
  default     = ""
}

variable "region_vault_role_id" {
  type        = string
  description = "dataserv AppRole role_id for the byo region Vault (from the region seed step). hashicorp provider only."
  default     = ""
}

variable "region_vault_secret_id" {
  type        = string
  description = "dataserv AppRole secret_id for the byo region Vault (short-TTL; prefer SSM/wrapped in real use). hashicorp provider only."
  sensitive   = true
  default     = ""
}

locals {
  region_provision_rds = var.region_db_mode == "provision-rds"
  region_hashicorp     = var.region_vault_provider == "hashicorp"
  # See variables.tf's hub_vault_ca_source for the ssm|system semantics.
  region_vault_ca_source = var.region_vault_ca_pem != "" ? "ssm" : "system"
  # No DB DSN is EVER a Terraform value. provision-rds: region-seed.sh builds
  # the DSN from region_db_host + region_db_secret_arn (AWS-managed password).
  # byo: the operator sets REGION_DB_URL in the region-seed environment —
  # Terraform neither needs nor stores it.
}
