# ---------- external Global HTTPS LB (client-facing hub) ----------
resource "google_compute_global_address" "appserv" {
  name = "${local.name_root}-appserv"
}

# Google-managed cert, DNS-validated automatically, only when dns_zone_name is
# supplied. Otherwise the operator must attach an existing cert (hub_certificate_id).
resource "google_compute_managed_ssl_certificate" "hub" {
  count = var.dns_zone_name != "" ? 1 : 0
  name  = "${local.name_root}-hub"
  managed {
    domains = [var.hub_domain]
  }
}

# Cloud Armor, created ONLY when client_cidr is narrowed. Client discovery on
# 443 arrives through the global HTTPS LB, whose frontend is a Google-managed
# proxy outside this VPC, so no firewall rule can source-filter it. Without this
# policy an operator who sets client_cidr gets dataserv and blockserv restricted
# while discovery stays open to the internet, which is the wrong direction for a
# security control to fail in.
#
# Cloud Armor is a chargeable product, which is why this is opt-in rather than
# always-on. The default (client_cidr = "0.0.0.0/0") creates nothing.
resource "google_compute_security_policy" "appserv" {
  count       = var.client_cidr == "0.0.0.0/0" ? 0 : 1
  name        = "${local.name_root}-appserv"
  description = "Restricts client discovery on 443 to client_cidr."

  rule {
    action   = "allow"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = [var.client_cidr]
      }
    }
    description = "Allow client_cidr"
  }

  # Rule 2147483647 is the mandatory catch-all; it must exist and must be last.
  rule {
    action   = "deny(403)"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default deny"
  }
}

resource "google_compute_backend_service" "appserv_http" {
  name                  = "${local.name_root}-appserv-http"
  protocol              = "HTTPS"
  port_name             = "https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_health_check.appserv.id]
  security_policy       = var.client_cidr == "0.0.0.0/0" ? null : google_compute_security_policy.appserv[0].id

  backend {
    group = google_compute_region_instance_group_manager.appserv.instance_group
  }
}

resource "google_compute_url_map" "appserv" {
  name            = "${local.name_root}-appserv"
  default_service = google_compute_backend_service.appserv_http.id
}

resource "google_compute_target_https_proxy" "appserv" {
  name             = "${local.name_root}-appserv"
  url_map          = google_compute_url_map.appserv.id
  ssl_certificates = var.dns_zone_name != "" ? [google_compute_managed_ssl_certificate.hub[0].id] : [var.hub_certificate_id]

  lifecycle {
    precondition {
      condition     = var.dns_zone_name != "" || var.hub_certificate_id != ""
      error_message = "Set dns_zone_name (for a Google-managed cert) or hub_certificate_id (an existing cert) for the HTTPS proxy."
    }
  }
}

resource "google_compute_global_forwarding_rule" "appserv_https" {
  name                  = "${local.name_root}-appserv-https"
  ip_address            = google_compute_global_address.appserv.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.appserv.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# ---------- internal TCP passthrough LB (SRPC :9443) ----------
# Internal: the SRPC control plane must not be internet-facing. Region services
# reach it from inside the VPC (preserves the original client source IP, unlike
# the external LB above).
resource "google_compute_region_backend_service" "appserv_srpc" {
  name                  = "${local.name_root}-appserv-srpc"
  region                = var.region
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_health_check.appserv_srpc.id]

  backend {
    group = google_compute_region_instance_group_manager.appserv.instance_group
  }
}

resource "google_compute_health_check" "appserv_srpc" {
  name = "${local.name_root}-appserv-srpc"
  tcp_health_check {
    port = 9443
  }
  healthy_threshold   = 2
  unhealthy_threshold = 3
  check_interval_sec  = 10
  timeout_sec         = 5
}

resource "google_compute_forwarding_rule" "appserv_srpc" {
  name                  = "${local.name_root}-appserv-srpc"
  region                = var.region
  ip_protocol           = "TCP"
  ports                 = ["9443"]
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.appserv_srpc.id
  subnetwork            = google_compute_subnetwork.private.id
  network               = google_compute_network.main.id
  allow_global_access   = true
}

output "srpc_lb_ip" {
  value = google_compute_forwarding_rule.appserv_srpc.ip_address
}
