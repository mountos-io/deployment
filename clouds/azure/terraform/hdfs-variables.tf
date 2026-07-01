# hdfsserv (WebHDFS gateway) vars. Opt-in; a stateless, cluster-wide protocol
# gateway, not tied to a storage type. Its Vault keys are seeded unconditionally
# by region-seed.sh; only running the fleet is gated by hdfs_enable.

variable "hdfs_enable" {
  type        = bool
  description = "Provision the hdfsserv (WebHDFS) gateway fleet."
  default     = false
}

variable "hdfs_count" {
  type        = number
  description = "Desired/min/max hdfsserv instances in the VMSS."
  default     = 2
}

variable "hdfs_vm_size" {
  type        = string
  description = "Azure VM size for hdfsserv (Dpsv5, arm64)."
  default     = "Standard_D4ps_v5"
}
