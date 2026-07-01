# Public DNS, only when an existing Cloud DNS managed zone is supplied.
data "google_dns_managed_zone" "hub" {
  count = var.dns_zone_name != "" ? 1 : 0
  name  = var.dns_zone_name
}

resource "google_dns_record_set" "hub" {
  count        = var.dns_zone_name != "" ? 1 : 0
  name         = "${var.hub_domain}."
  type         = "A"
  ttl          = 60
  managed_zone = data.google_dns_managed_zone.hub[0].name
  rrdatas      = [google_compute_global_address.appserv.address]
}

# Publishes the internal SRPC LB address for operator/discovery convenience
# (mirrors AWS's route53.tf). Region cloud-init templates use the LB IP
# output directly, not this record - it resolves publicly but only routes
# from networks with a path to the internal forwarding rule (VPC/peered).
resource "google_dns_record_set" "srpc" {
  count        = var.dns_zone_name != "" ? 1 : 0
  name         = "srpc.${var.hub_domain}."
  type         = "A"
  ttl          = 60
  managed_zone = data.google_dns_managed_zone.hub[0].name
  rrdatas      = [google_compute_forwarding_rule.appserv_srpc.ip_address]
}
