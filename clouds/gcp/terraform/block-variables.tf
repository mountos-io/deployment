# blockserv (block data-plane) vars. Opt-in; only for local-block backends.
# Its Vault keys are seeded unconditionally by region-seed.sh; only running the
# fleet is gated by block_enable. Reuses region vars (region_cluster_id,
# region_vault_*, mos_version, mode) and hub resources (local.machine_image,
# region_public_subnet, blockserv firewall tag).

variable "block_enable" {
  type        = bool
  description = "Provision blockserv. Only needed for local-block backends."
  default     = false
}

variable "block_members" {
  type = list(object({
    block_volume_id = string
    zone_index      = number
  }))
  description = "Active-active members of a block storage (up to 3, distinct zones). Each has its own block volume UUID from hub storage provisioning; zone_index selects the zone."
  default     = []
}

variable "block_machine_type" {
  type        = string
  description = "GCE machine type for blockserv (network-optimized Tau T2A)."
  default     = "t2a-standard-8"
}

variable "block_cache_gb" {
  type        = number
  description = "Cache disk size (GiB), throughput-oriented."
  default     = 500
}

variable "block_cache_type" {
  type        = string
  description = "Cache disk type."
  default     = "pd-ssd"
  validation {
    condition     = contains(["pd-ssd", "pd-balanced", "pd-extreme"], var.block_cache_type)
    error_message = "block_cache_type must be pd-ssd, pd-balanced, or pd-extreme."
  }
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
  block_members_map = var.block_enable ? { for m in var.block_members : m.block_volume_id => m } : {}
}
