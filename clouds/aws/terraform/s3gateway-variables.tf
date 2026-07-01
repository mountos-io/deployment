# s3gatewayserv (S3 REST gateway) vars. Opt-in; a stateless, cluster-wide
# protocol gateway, not tied to a storage type. Its Vault keys are seeded
# unconditionally by region-seed.sh; only running the fleet is gated by
# s3gateway_enable. Reuses region vars (region_cluster_id, region_vault_*,
# mos_version, mode) and hub resources (local.ami, aws_lb.appserv_srpc,
# aws_security_group.gateway, aws_subnet.private).

variable "s3gateway_enable" {
  type        = bool
  description = "Provision the s3gatewayserv (S3 REST) gateway fleet."
  default     = false
}

variable "s3gateway_count" {
  type        = number
  description = "Desired/min/max s3gatewayserv instances in the ASG."
  default     = 2
}

variable "s3gateway_instance_type" {
  type        = string
  description = "EC2 instance type for s3gatewayserv (arm64)."
  default     = "m7g.xlarge"
}
