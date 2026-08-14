# GCP firewall rules are network-wide, filtered by target/source tags (not
# "security groups" attached to instances like AWS) — and strictly PER
# NETWORK: a rule on the hub network never applies to the region network, even
# once peered. Each mountOS tier gets a network tag; SAME-network rules use
# tags (mirrors AWS SG-to-SG references); CROSS-network rules (hub<->region,
# dedicated mode only) use CIDR ranges instead, since tag matching doesn't
# cross the peering boundary — same reasoning as the AWS module's dedicated-mode
# CIDR rules.
#
# IMPORTANT: blockserv otherwise picks a DYNAMIC SRPC port (ephemeral :0),
# which cannot be firewalled. Deploy MUST set PORT_RANGE on that service to
# exactly the range below so appserv -> service SRPC is allowed.

# Client-facing ports are INTERNET-FACING BY DESIGN and default to 0.0.0.0/0.
# These are the surfaces real users reach from arbitrary networks: dataserv
# 6464 (clients mount) and blockserv 9100 (client byte plane). Access control
# for both is at the APPLICATION layer, not the network: Noise plus per-volume
# access keys on the data path and a signed JWT on the Admin API. A source-IP
# allowlist adds no real protection there — it only breaks legitimate clients,
# and pinning it to an operator's own dynamic/residential address silently
# locks the whole deployment out when the ISP rotates it (packets are DROPPED,
# so every request hangs with no error).
#
# GCP mechanism note: this variable drives the two VPC firewall rules below AND
# a Cloud Armor policy in lb.tf. appserv 443 arrives through the GLOBAL HTTPS
# LB, whose frontend is a Google-managed proxy outside this VPC, so no firewall
# rule can source-filter it; the Cloud Armor policy on the backend service is
# what restricts discovery. That policy is created ONLY when client_cidr is
# narrowed, because Cloud Armor is chargeable.
#
# Narrowing it is still supported for a private/single-tenant deployment that
# genuinely fronts these with a VPN or fixed office range — set it explicitly
# in that case. Do NOT narrow it on a deployment serving real clients.
variable "client_cidr" {
  description = "CIDR allowed to reach client-facing ports (appserv 443, dataserv 6464, blockserv 9100). Defaults to 0.0.0.0/0: these are internet-facing by design and authenticated at the application layer. Narrowing it also creates a chargeable Cloud Armor policy, which is the only way to source-filter 443 behind the global HTTPS LB. Narrow only for a private deployment fronted by a VPN/fixed range."
  type        = string
  default     = "0.0.0.0/0"
}

# Opt-in break-glass SSH (default OFF - no path exists at all unless set).
# Documents and gates the ONLY sanctioned SSH entry: Identity-Aware Proxy TCP
# forwarding, never a direct 0.0.0.0/0 (or any other) rule on port 22.
# Instances already have enable-oslogin=true + block-project-ssh-keys=true
# (compute.tf etc.) so this rule alone doesn't grant login - IAM's
# roles/iap.tunnelResourceAccessor + roles/compute.osLogin are also required.
variable "iap_ssh_enable" {
  description = "Allow SSH via IAP TCP forwarding (source 35.235.240.0/20 only). Default false: no SSH path exists at all unless explicitly turned on."
  type        = bool
  default     = false
}

locals {
  srpc_range_from = 9500
  srpc_range_to   = 9600 # set PORT_RANGE=9500-9600 on blockserv

  # Google's published health-check + LB source ranges (both external HTTP(S)
  # and internal TCP/UDP LB health probing).
  google_lb_ranges = ["130.211.0.0/22", "35.191.0.0/16"]

  # Google's fixed IAP TCP forwarding source range - never anything broader.
  iap_ssh_range = "35.235.240.0/20"
  all_tags = [
    "mountos-appserv", "mountos-dataserv", "mountos-gcserv",
    "mountos-blockserv",
  ]
}

resource "google_compute_firewall" "iap_ssh_hub" {
  count         = var.iap_ssh_enable ? 1 : 0
  name          = "${local.name_root}-iap-ssh-hub"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  target_tags   = local.all_tags
  source_ranges = [local.iap_ssh_range]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "iap_ssh_region" {
  count         = var.iap_ssh_enable && local.region_dedicated_vpc ? 1 : 0
  name          = "${local.name_root}-iap-ssh-region"
  network       = local.region_network
  direction     = "INGRESS"
  target_tags   = local.all_tags
  source_ranges = [local.iap_ssh_range]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# ---------- default egress: allow all, both networks (GCP firewalls don't
# cascade across a peering boundary — each network needs its own rule) ----------
resource "google_compute_firewall" "egress_all" {
  name      = "${local.name_root}-egress-all"
  network   = google_compute_network.main.id
  direction = "EGRESS"
  priority  = 65534
  allow {
    protocol = "all"
  }
  destination_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "egress_all_region" {
  count     = local.region_dedicated_vpc ? 1 : 0
  name      = "${local.name_root}-region-egress-all"
  network   = google_compute_network.region[0].id
  direction = "EGRESS"
  priority  = 65534
  allow {
    protocol = "all"
  }
  destination_ranges = ["0.0.0.0/0"]
}

# ---------- appserv ingress (hub network) ----------
resource "google_compute_firewall" "appserv_https_from_lb" {
  name          = "${local.name_root}-appserv-https-from-lb"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  target_tags   = ["mountos-appserv"]
  source_ranges = local.google_lb_ranges
  allow {
    protocol = "tcp"
    ports    = ["8443"]
  }
}

# Client HTTPS to the LB itself is a Cloud Armor / LB frontend concern, not an
# instance firewall rule (the external HTTPS LB terminates TLS at Google's
# edge). lb.tf attaches google_compute_security_policy.appserv to the backend
# service when client_cidr is narrowed; that policy, not a rule here, is what
# restricts client discovery on 443.

# shared mode: tag-based (same network). dedicated mode: CIDR-based (region
# network), since tags don't match across the peering boundary.
resource "google_compute_firewall" "appserv_srpc_from_dataserv" {
  count       = local.region_dedicated_vpc ? 0 : 1
  name        = "${local.name_root}-appserv-srpc-from-dataserv"
  network     = google_compute_network.main.id
  direction   = "INGRESS"
  target_tags = ["mountos-appserv"]
  source_tags = ["mountos-dataserv"]
  allow {
    protocol = "tcp"
    ports    = ["9443"]
  }
}

resource "google_compute_firewall" "appserv_srpc_from_gcserv" {
  count       = local.region_dedicated_vpc ? 0 : 1
  name        = "${local.name_root}-appserv-srpc-from-gcserv"
  network     = google_compute_network.main.id
  direction   = "INGRESS"
  target_tags = ["mountos-appserv"]
  source_tags = ["mountos-gcserv"]
  allow {
    protocol = "tcp"
    ports    = ["9443"]
  }
}

resource "google_compute_firewall" "appserv_srpc_from_blockserv" {
  count       = local.region_dedicated_vpc ? 0 : 1
  name        = "${local.name_root}-appserv-srpc-from-blockserv"
  network     = google_compute_network.main.id
  direction   = "INGRESS"
  target_tags = ["mountos-appserv"]
  source_tags = ["mountos-blockserv"]
  allow {
    protocol = "tcp"
    ports    = ["9443"]
  }
}

# dedicated mode: one CIDR-based rule covers all region services (same
# port) on the region VPC's public subnet (the only region subnet — every
# region workload advertises a public IPv4).
resource "google_compute_firewall" "appserv_srpc_from_region_cidr" {
  count         = local.region_dedicated_vpc ? 1 : 0
  name          = "${local.name_root}-appserv-srpc-from-region-cidr"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  target_tags   = ["mountos-appserv"]
  source_ranges = [var.region_vpc_cidr_public]
  allow {
    protocol = "tcp"
    ports    = ["9443"]
  }
}

# Internal passthrough LB health checks probe SRPC :9443 from Google's ranges
# (never from the client's IP, which the tag/CIDR rules above cover) — without
# this rule every SRPC backend stays permanently unhealthy. The 8443 HTTPS LB
# probe is covered by appserv_https_from_lb above (same source ranges).
resource "google_compute_firewall" "appserv_srpc_health_check" {
  name          = "${local.name_root}-appserv-srpc-health-check"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  target_tags   = ["mountos-appserv"]
  source_ranges = local.google_lb_ranges
  allow {
    protocol = "tcp"
    ports    = ["9443"]
  }
}

# ---------- dataserv ingress (region network) ----------
resource "google_compute_firewall" "dataserv_client" {
  name          = "${local.name_root}-dataserv-client"
  network       = local.region_network
  direction     = "INGRESS"
  target_tags   = ["mountos-dataserv"]
  source_ranges = [var.client_cidr]
  allow {
    protocol = "tcp"
    ports    = ["6464"]
  }
}

# Unlike AWS's ASG (health_check_type = "EC2", a pure instance-status check
# with no network path), a GCP MIG's auto_healing_policies ALWAYS does a real
# TCP/HTTP probe from Google's published ranges — without this rule the probe
# is firewalled off, every instance is marked UNHEALTHY forever, and the MIG
# auto-heals in an endless recreate loop. dataserv isn't LB-fronted, so this
# was missing (only appserv's LB-fronted ports had a health-check rule).
resource "google_compute_firewall" "dataserv_health_check" {
  name          = "${local.name_root}-dataserv-health-check"
  network       = local.region_network
  direction     = "INGRESS"
  target_tags   = ["mountos-dataserv"]
  source_ranges = local.google_lb_ranges
  allow {
    protocol = "tcp"
    ports    = ["6464"]
  }
}

resource "google_compute_firewall" "dataserv_raft_self" {
  name        = "${local.name_root}-dataserv-raft-self"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-dataserv"]
  source_tags = ["mountos-dataserv"]
  allow {
    protocol = "tcp"
    ports    = ["6465"]
  }
}

# The raft JOIN handshake is separate from the raft data plane above: a joining
# node dials an existing peer's SRPC/RPC port (6466), not the raft port (6465),
# to ask for admission. Without this, a fresh node self-bootstraps alone and
# every other node retries "no peer accepted join request" forever — a
# permanent single-node quorum that still reports healthy per node. Self-tagged
# like the 6465 rule so it holds in both shared and dedicated region-VPC modes;
# the appserv-sourced 6466 rule below is a different source, not a substitute.
resource "google_compute_firewall" "dataserv_rpc_self" {
  name        = "${local.name_root}-dataserv-rpc-self"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-dataserv"]
  source_tags = ["mountos-dataserv"]
  allow {
    protocol = "tcp"
    ports    = ["6466"]
  }
}

resource "google_compute_firewall" "dataserv_srpc_from_appserv" {
  count       = local.region_dedicated_vpc ? 0 : 1
  name        = "${local.name_root}-dataserv-srpc-from-appserv"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-dataserv"]
  source_tags = ["mountos-appserv"]
  allow {
    protocol = "tcp"
    ports    = ["6466"]
  }
}

resource "google_compute_firewall" "dataserv_srpc_from_appserv_cidr" {
  count         = local.region_dedicated_vpc ? 1 : 0
  name          = "${local.name_root}-dataserv-srpc-from-appserv-cidr"
  network       = local.region_network
  direction     = "INGRESS"
  target_tags   = ["mountos-dataserv"]
  source_ranges = [var.vpc_cidr_public, var.vpc_cidr_private]
  allow {
    protocol = "tcp"
    ports    = ["6466"]
  }
}

# ---------- gcserv ingress (region network) ----------
# Applies to CO-LOCATED gcserv too: region-compute.tf tags the dataserv
# instances "mountos-gcserv" as well when gcserv_colocated, so port 8081 below
# is the port the co-located unit must actually bind. That is why its systemd
# unit pins RPC_PORT=8081 rather than letting it derive from the overridden
# PORT — a derived port would land outside this rule.
resource "google_compute_firewall" "gcserv_srpc_from_appserv" {
  count       = local.region_dedicated_vpc ? 0 : 1
  name        = "${local.name_root}-gcserv-srpc-from-appserv"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-gcserv"]
  source_tags = ["mountos-appserv"]
  allow {
    protocol = "tcp"
    ports    = ["8081"]
  }
}

resource "google_compute_firewall" "gcserv_srpc_from_appserv_cidr" {
  count         = local.region_dedicated_vpc ? 1 : 0
  name          = "${local.name_root}-gcserv-srpc-from-appserv-cidr"
  network       = local.region_network
  direction     = "INGRESS"
  target_tags   = ["mountos-gcserv"]
  source_ranges = [var.vpc_cidr_public, var.vpc_cidr_private]
  allow {
    protocol = "tcp"
    ports    = ["8081"]
  }
}

# ---------- blockserv ingress (region network) ----------
resource "google_compute_firewall" "blockserv_client" {
  name          = "${local.name_root}-blockserv-client"
  network       = local.region_network
  direction     = "INGRESS"
  target_tags   = ["mountos-blockserv"]
  source_ranges = [var.client_cidr]
  allow {
    protocol = "tcp"
    ports    = ["9100"]
  }
}

resource "google_compute_firewall" "blockserv_peer_self" {
  name        = "${local.name_root}-blockserv-peer-self"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-blockserv"]
  source_tags = ["mountos-blockserv"]
  allow {
    protocol = "tcp"
    ports    = ["9101"]
  }
}

resource "google_compute_firewall" "blockserv_srpc_from_appserv" {
  count       = local.region_dedicated_vpc ? 0 : 1
  name        = "${local.name_root}-blockserv-srpc-from-appserv"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-blockserv"]
  source_tags = ["mountos-appserv"]
  allow {
    protocol = "tcp"
    ports    = ["${local.srpc_range_from}-${local.srpc_range_to}"]
  }
}

resource "google_compute_firewall" "blockserv_srpc_from_appserv_cidr" {
  count         = local.region_dedicated_vpc ? 1 : 0
  name          = "${local.name_root}-blockserv-srpc-from-appserv-cidr"
  network       = local.region_network
  direction     = "INGRESS"
  target_tags   = ["mountos-blockserv"]
  source_ranges = [var.vpc_cidr_public, var.vpc_cidr_private]
  allow {
    protocol = "tcp"
    ports    = ["${local.srpc_range_from}-${local.srpc_range_to}"]
  }
}
