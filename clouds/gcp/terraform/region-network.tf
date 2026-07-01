# Region network placement. shared (default): region resources live in the
# hub's network (google_compute_network.main). dedicated: the region gets its
# own VPC network in the SAME GCP project and region, connected via VPC
# Network Peering. Unlike AWS, GCP peering auto-exchanges subnet routes on
# both sides — no manual route-table entries needed. Cross-network firewall
# rules still need explicit CIDR-based source_ranges (GCP firewall rules are
# per-network; a peer's tags aren't visible across the peering boundary the
# way AWS SG-to-SG references need same-VPC — CIDR is the portable choice).
#
# NOT covered here: true cross-project regions (needs peering across projects,
# explicit accepter-side consent) or a different GCP region (needs region-
# scoped subnet CIDR planning across two regions). Both are separate changes.
variable "region_vpc_mode" {
  type        = string
  description = "Region network placement: shared (default; region resources live in the hub network) | dedicated (region gets its own VPC network, peered to the hub network)."
  default     = "shared"
  validation {
    condition     = contains(["shared", "dedicated"], var.region_vpc_mode)
    error_message = "region_vpc_mode must be shared or dedicated."
  }
}

variable "region_vpc_cidr_public" {
  type    = string
  default = "10.1.0.0/24"
}

variable "region_vpc_cidr_private" {
  type    = string
  default = "10.1.10.0/24"
}

locals {
  region_dedicated_vpc = var.region_vpc_mode == "dedicated"

  region_network        = local.region_dedicated_vpc ? google_compute_network.region[0].id : google_compute_network.main.id
  region_public_subnet  = local.region_dedicated_vpc ? google_compute_subnetwork.region_public[0] : google_compute_subnetwork.public
  region_private_subnet = local.region_dedicated_vpc ? google_compute_subnetwork.region_private[0] : google_compute_subnetwork.private
}

resource "google_compute_network" "region" {
  count                   = local.region_dedicated_vpc ? 1 : 0
  name                    = "mountos-region"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "region_public" {
  count         = local.region_dedicated_vpc ? 1 : 0
  name          = "mountos-region-public"
  network       = google_compute_network.region[0].id
  ip_cidr_range = var.region_vpc_cidr_public
  region        = var.region
}

resource "google_compute_subnetwork" "region_private" {
  count                    = local.region_dedicated_vpc ? 1 : 0
  name                     = "mountos-region-private"
  network                  = google_compute_network.region[0].id
  ip_cidr_range            = var.region_vpc_cidr_private
  region                   = var.region
  private_ip_google_access = true
}

resource "google_compute_router" "region_nat" {
  count   = local.region_dedicated_vpc ? 1 : 0
  name    = "mountos-region-nat-router"
  network = google_compute_network.region[0].id
  region  = var.region
}

resource "google_compute_router_nat" "region_nat" {
  count                              = local.region_dedicated_vpc ? 1 : 0
  name                               = "mountos-region-nat"
  router                             = google_compute_router.region_nat[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.region_private[0].id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# Both directions required — GCP peering is not implicitly bidirectional like
# a single AWS aws_vpc_peering_connection (auto_accept). Routes and (if
# enabled) DNS both exchange automatically once both sides are up.
resource "google_compute_network_peering" "hub_to_region" {
  count        = local.region_dedicated_vpc ? 1 : 0
  name         = "mountos-hub-to-region"
  network      = google_compute_network.main.id
  peer_network = google_compute_network.region[0].id
}

resource "google_compute_network_peering" "region_to_hub" {
  count        = local.region_dedicated_vpc ? 1 : 0
  name         = "mountos-region-to-hub"
  network      = google_compute_network.region[0].id
  peer_network = google_compute_network.main.id
}

output "region_network_id" {
  value = local.region_dedicated_vpc ? google_compute_network.region[0].id : null
}
