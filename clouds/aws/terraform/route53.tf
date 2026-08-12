# Public DNS, only when an existing hosted zone is supplied AND the ALB path is
# in use. direct-IP mode (var.appserv_direct_ip) has no ALB/NLB alias target —
# point hub_domain at aws_eip.appserv's public_ip with a plain Cloudflare/etc.
# A record instead (outside Terraform, the operator's own DNS provider).
# ACM validation records live in lb.tf to keep them next to the cert.
resource "aws_route53_record" "hub" {
  count   = !var.appserv_direct_ip && var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.hub_domain
  type    = "A"

  alias {
    name                   = aws_lb.appserv[0].dns_name
    zone_id                = aws_lb.appserv[0].zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "srpc" {
  count   = !var.appserv_direct_ip && var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "srpc.${var.hub_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.appserv_srpc[0].dns_name
    zone_id                = aws_lb.appserv_srpc[0].zone_id
    evaluate_target_health = true
  }
}
