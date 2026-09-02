# blockserv (block data-plane) vars. Opt-in; only for local-block backends.
# Its Vault keys are seeded unconditionally by region-seed.sh; only running the
# fleet is gated by block_enable. Reuses region vars (region_cluster_id,
# region_vault_*, mos_version, mode) and hub resources (data.aws_ami.al2023_arm64,
# aws_lb.appserv_srpc, aws_security_group.blockserv, aws_subnet.private).

variable "block_enable" {
  type        = bool
  description = "Provision blockserv. Only needed for local-block backends."
  default     = false
}

variable "block_members" {
  type = list(object({
    block_volume_id = string
    az_index        = number
    # Stable Elastic IP (default) vs the subnet's auto-assigned ephemeral public IP.
    # An EIP is the right default (see block-compute.tf's file header for why), but
    # each one counts against the account's EC2-VPC Elastic IP quota; set false for
    # a member added past that quota rather than requesting an increase every time.
    # Real tradeoff: an ephemeral address is NOT stable across an instance stop/start
    # (a binary/process redeploy on a running instance is unaffected either way).
    use_eip = optional(bool, true)
  }))
  description = "Every blockserv instance to provision for this block storage, however many. Pairing into copysets (two members each) happens on the hub before this list is built, via registerCopyset/registerCopysetsBulk, which mints each member's block volume UUID; list every minted UUID here. az_index selects the private subnet/AZ - putting a copyset's two members in different AZs is advised for fault isolation, not enforced or tracked by mountOS."
  default     = []
}

variable "block_instance_type" {
  type        = string
  description = "EC2 instance type for blockserv (network-enhanced arm64 family)."
  default     = "m7gn.2xlarge"
}

variable "block_cache_gb" {
  type        = number
  description = "Cache EBS volume size (GiB), throughput-oriented."
  default     = 500
}

variable "block_cache_type" {
  type        = string
  description = "Cache EBS volume type."
  default     = "gp3"
  validation {
    condition     = contains(["gp3", "io1", "io2"], var.block_cache_type)
    error_message = "block_cache_type must be gp3, io1, or io2."
  }
}

variable "block_cache_iops" {
  type        = number
  description = "Provisioned IOPS for the cache EBS volume."
  default     = 4000
}

variable "block_cache_throughput" {
  type        = number
  description = "Provisioned throughput (MiB/s) for the cache EBS volume."
  default     = 250
}

variable "block_delete_mode" {
  type        = string
  description = "blockserv DELETE_MODE."
  default     = "secured"
  validation {
    condition     = contains(["normal", "secured", "secured-immediate"], var.block_delete_mode)
    error_message = "block_delete_mode must be normal, secured, or secured-immediate."
  }
}

locals {
  # for_each keyed by the unique block volume UUID per member.
  block_members_map = var.block_enable ? { for m in var.block_members : m.block_volume_id => m } : {}
}
