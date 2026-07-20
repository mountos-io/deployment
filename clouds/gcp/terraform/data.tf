# Project lookup: Secret Manager IAM conditions match on resource names that
# carry the project NUMBER, not the id (region-iam.tf).
data "google_project" "current" {
  project_id = var.project_id
}

# Image for appserv, dataserv, and blockserv.
# Default: look up the latest Debian 12 arm64. Set var.machine_image to PIN a
# specific image (family or full self_link) for reproducible/production rollouts.
variable "machine_image" {
  type        = string
  description = "Pin a specific machine image (self_link). Empty looks up the latest Debian 12 arm64."
  default     = ""
}

data "google_compute_image" "debian12_arm64" {
  count   = var.machine_image == "" ? 1 : 0
  family  = "debian-12-arm64"
  project = "debian-cloud"
}

locals {
  machine_image = var.machine_image != "" ? var.machine_image : data.google_compute_image.debian12_arm64[0].self_link
}
