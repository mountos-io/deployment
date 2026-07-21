# ---------- ALB SG: public HTTPS to appserv:8080 ----------
resource "aws_security_group" "alb" {
  name        = "${local.name_root}-alb"
  description = "ALB: public HTTPS for hub"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name_root}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = var.client_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "client HTTPS"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ALB -> appserv:8443 (re-encrypt: ALB terminates client TLS, re-encrypts to appserv).
resource "aws_vpc_security_group_ingress_rule" "appserv_http_from_alb" {
  security_group_id            = aws_security_group.appserv.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8443
  to_port                      = 8443
  ip_protocol                  = "tcp"
  description                  = "HTTPS from ALB"
}

# ---------- ACM: only when a hosted zone is supplied (DNS validation) ----------
resource "aws_acm_certificate" "hub" {
  count             = var.route53_zone_id != "" ? 1 : 0
  domain_name       = var.hub_domain
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
  tags = { Name = "${local.name_root}-hub" }
}

resource "aws_route53_record" "hub_cert_validation" {
  for_each = var.route53_zone_id != "" ? {
    for dvo in aws_acm_certificate.hub[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "hub" {
  count                   = var.route53_zone_id != "" ? 1 : 0
  certificate_arn         = aws_acm_certificate.hub[0].arn
  validation_record_fqdns = [for r in aws_route53_record.hub_cert_validation : r.fqdn]
}

# ---------- ALB (HTTP/HTTPS hub) ----------
resource "aws_lb" "appserv" {
  name               = "${local.name_root}-appserv"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = { Name = "${local.name_root}-appserv" }
}

resource "aws_lb_target_group" "appserv_http" {
  name        = "${local.name_root}-appserv-http"
  port        = 8443
  protocol    = "HTTPS"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # Re-encrypt to appserv (self-signed). Listener-alive probe: any non-5xx means
  # appserv is up; tolerant of auth-behavior changes, still fails on 5xx.
  health_check {
    protocol = "HTTPS"
    path     = "/api/v1/me"
    matcher  = "200-499"
  }

  tags = { Name = "${local.name_root}-appserv-http" }
}

# certificate_arn is set only when route53_zone_id is supplied. Otherwise the operator
# must attach a cert ARN to this listener (ACM import or external issuance).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.appserv.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.route53_zone_id != "" ? aws_acm_certificate_validation.hub[0].certificate_arn : var.hub_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.appserv_http.arn
  }

  lifecycle {
    precondition {
      condition     = var.route53_zone_id != "" || var.hub_certificate_arn != ""
      error_message = "Set route53_zone_id (for ACM DNS validation) or hub_certificate_arn (an existing cert) for the HTTPS listener."
    }
  }
}

# ---------- NLB (SRPC :9443 passthrough) ----------
# Internal: the SRPC control plane must not be internet-facing. Region services
# reach it from inside the VPC.
resource "aws_lb" "appserv_srpc" {
  name               = "${local.name_root}-appserv-srpc"
  internal           = true
  load_balancer_type = "network"
  subnets            = aws_subnet.public[*].id
  tags               = { Name = "${local.name_root}-appserv-srpc" }

  # appserv_count (2) < AZ count (3): without cross-zone an NLB node in the
  # AZ that has no appserv target would fail connections routed to its IP.
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "appserv_srpc" {
  name        = "${local.name_root}-appserv-srpc"
  port        = 9443
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "9443"
  }

  tags = { Name = "${local.name_root}-appserv-srpc" }
}

resource "aws_lb_listener" "srpc" {
  load_balancer_arn = aws_lb.appserv_srpc.arn
  port              = 9443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.appserv_srpc.arn
  }
}
