# Image for appserv, dataserv, blockserv, and the self-hosted Vault nodes.
# Ubuntu 22.04 LTS arm64. Azure resolves marketplace images via a reference
# (publisher/offer/sku/version), not a lookup data source like AWS AMI/GCP
# image family — set image_version to PIN a specific version for
# reproducible/production rollouts (default "latest").
variable "image_version" {
  type        = string
  description = "Marketplace image version. Empty resolves to latest."
  default     = "latest"
}

locals {
  image_reference = {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-arm64"
    version   = var.image_version != "" ? var.image_version : "latest"
  }
}
