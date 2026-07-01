# blockserv (block data-plane) vars. Opt-in; only for local-block backends.
# Its Vault keys are seeded unconditionally by region-seed.sh; only running the
# fleet is gated by block_enable.

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

variable "block_vm_size" {
  type        = string
  description = "Azure VM size for blockserv (network-optimized Dpsv5)."
  default     = "Standard_D8ps_v5"
}

variable "block_cache_gb" {
  type        = number
  description = "Cache disk size (GiB), throughput-oriented."
  default     = 500
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
