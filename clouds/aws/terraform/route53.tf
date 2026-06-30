# Public DNS, only when an existing hosted zone is supplied.
# ACM validation records live in lb.tf to keep them next to the cert.
resource "aws_route53_record" "hub" {
  count   = var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.hub_domain
  type    = "A"

  alias {
    name                   = aws_lb.appserv.dns_name
    zone_id                = aws_lb.appserv.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "srpc" {
  count   = var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "srpc.${var.hub_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.appserv_srpc.dns_name
    zone_id                = aws_lb.appserv_srpc.zone_id
    evaluate_target_health = true
  }
}
