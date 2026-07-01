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
  description = "Desired/min/max hdfsserv instances in the MIG."
  default     = 2
}

variable "hdfs_machine_type" {
  type        = string
  description = "GCE machine type for hdfsserv (Tau T2A, arm64)."
  default     = "t2a-standard-4"
}
