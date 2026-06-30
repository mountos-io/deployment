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

variable "region_db_url" {
  type        = string
  description = "Full region DB DSN. Used only when region_db_mode = byo."
  default     = ""
}

variable "region_db_username" {
  type        = string
  description = "Region RDS master username (provision-rds mode)."
  default     = "mountos"
}

variable "region_db_password" {
  type        = string
  description = "Region RDS master password (provision-rds mode)."
  sensitive   = true
  default     = ""
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

variable "region_vault_hosting" {
  type        = string
  description = "Region Vault hosting: self-hosted (provision an EC2 Vault) | managed-byo (use region_vault_addr)."
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
  description = "dataserv AppRole secret_id for the region Vault (short-TTL; prefer SSM/wrapped in real use)."
  sensitive   = true
  default     = ""
}

variable "region_vault_instance_type" {
  type        = string
  description = "EC2 instance type for the self-hosted region Vault node (arm64)."
  default     = "t4g.medium"
}

locals {
  region_provision_rds  = var.region_db_mode == "provision-rds"
  region_self_vault     = var.region_vault_hosting == "self-hosted"
  region_vault_endpoint = local.region_self_vault ? "https://${aws_instance.region_vault[0].private_ip}:8200" : var.region_vault_addr
  region_dsn            = local.region_provision_rds ? "postgresql://${var.region_db_username}:${var.region_db_password}@${aws_db_instance.region[0].endpoint}/mountos_data?sslmode=require" : var.region_db_url
}
