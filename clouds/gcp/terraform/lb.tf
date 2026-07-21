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

resource "google_compute_backend_service" "appserv_http" {
  name                  = "${local.name_root}-appserv-http"
  protocol              = "HTTPS"
  port_name             = "https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_health_check.appserv.id]

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
