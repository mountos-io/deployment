# GCP has no per-AZ subnet model like AWS: a single regional subnetwork spans
# every zone in the region, and per-instance/MIG zone placement (not subnet
# choice) is what spreads a fleet across zones for HA. "public"/"private" here
# is an INSTANCE property in GCP (whether its NIC has an access_config, i.e. an
# external IP), not a subnet property — we still split into two subnets (like
# AWS's public/private) so Cloud NAT can be scoped to just the private one and
# the file/variable names stay legible against the AWS module.

variable "vpc_cidr_public" {
  type    = string
  default = "10.0.0.0/24"
}

variable "vpc_cidr_private" {
  type    = string
  default = "10.0.10.0/24"
}

# Zones this fleet spreads across (HA). GCP picks the zone per-instance/MIG,
# not per-subnet.
variable "zones" {
  type        = list(string)
  description = "Zones within var.region to spread instances across (HA). Defaults to the region's a/b/c zones."
  default     = []
}

locals {
  zones = length(var.zones) > 0 ? var.zones : [for s in ["a", "b", "c"] : "${var.region}-${s}"]
}

resource "google_compute_network" "main" {
  name                    = local.name_root
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "public" {
  name          = "${local.name_root}-public"
  network       = google_compute_network.main.id
  ip_cidr_range = var.vpc_cidr_public
  region        = var.region
}

resource "google_compute_subnetwork" "private" {
  name                     = "${local.name_root}-private"
  network                  = google_compute_network.main.id
  ip_cidr_range            = var.vpc_cidr_private
  region                   = var.region
  private_ip_google_access = true
}

# Cloud NAT for the private subnet's egress (n.sh installer, package fetches,
# Vault/API calls out). Public-subnet instances use their own external IP.
resource "google_compute_router" "nat" {
  name    = "${local.name_root}-nat-router"
  network = google_compute_network.main.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${local.name_root}-nat"
  router                             = google_compute_router.nat.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

output "network_id" {
  value = google_compute_network.main.id
}

output "public_subnet_id" {
  value = google_compute_subnetwork.public.id
}

output "private_subnet_id" {
  value = google_compute_subnetwork.private.id
}
