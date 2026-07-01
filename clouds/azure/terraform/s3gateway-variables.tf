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
  description = "Desired/min/max s3gatewayserv instances in the VMSS."
  default     = 2
}

variable "s3gateway_vm_size" {
  type        = string
  description = "Azure VM size for s3gatewayserv (Dpsv5, arm64)."
  default     = "Standard_D4ps_v5"
}
