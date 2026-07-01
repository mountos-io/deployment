# hdfsserv (WebHDFS gateway) vars. Opt-in; a stateless, cluster-wide protocol
# gateway, not tied to a storage type. Its Vault keys are seeded unconditionally
# by region-seed.sh; only running the fleet is gated by hdfs_enable. Reuses
# region vars (region_cluster_id, region_vault_*, mos_version, mode) and hub
# resources (local.ami, aws_lb.appserv_srpc, aws_security_group.gateway,
# aws_subnet.private).

variable "hdfs_enable" {
  type        = bool
  description = "Provision the hdfsserv (WebHDFS) gateway fleet."
  default     = false
}

variable "hdfs_count" {
  type        = number
  description = "Desired/min/max hdfsserv instances in the ASG."
  default     = 2
}

variable "hdfs_instance_type" {
  type        = string
  description = "EC2 instance type for hdfsserv (arm64)."
  default     = "m7g.xlarge"
}
