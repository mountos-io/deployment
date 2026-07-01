# s3gatewayserv (S3 REST gateway) vars. Opt-in; a stateless, cluster-wide
# protocol gateway, not tied to a storage type. Its Vault keys are seeded
# unconditionally by region-seed.sh; only running the fleet is gated by
# s3gateway_enable.

variable "s3gateway_enable" {
  type        = bool
  description = "Provision the s3gatewayserv (S3 REST) gateway fleet."
  default     = false
}

variable "s3gateway_count" {
  type        = number
  description = "Desired/min/max s3gatewayserv instances in the MIG."
  default     = 2
}

variable "s3gateway_machine_type" {
  type        = string
  description = "GCE machine type for s3gatewayserv (Tau T2A, arm64)."
  default     = "t2a-standard-4"
}
