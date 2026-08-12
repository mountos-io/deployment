# Direct-IP appserv path — used only when var.appserv_direct_ip = true. Single
# instance (appserv_count must be 1, enforced by the variable's validation),
# own Elastic IP, own public subnet, Caddy terminates a real Let's Encrypt cert
# for hub_domain and reverse-proxies to appserv's own self-signed HTTPS on
# 127.0.0.1:8443 (same re-encrypt shape the ALB path uses, just Caddy instead
# of an AWS-managed LB). SRPC 9443 is exposed directly through the security
# group — it's Noise-encrypted at the application layer already, so it needs
# no LB/TLS of its own, matching how dataserv/blockserv are already reached.
resource "aws_eip" "appserv" {
  count  = var.appserv_direct_ip ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.name_root}-appserv" }
}

resource "aws_eip_association" "appserv" {
  count         = var.appserv_direct_ip ? 1 : 0
  instance_id   = aws_instance.appserv_direct[0].id
  allocation_id = aws_eip.appserv[0].id
}

resource "aws_instance" "appserv_direct" {
  count                  = var.appserv_direct_ip ? 1 : 0
  ami                    = local.ami
  instance_type          = var.appserv_instance_type
  subnet_id              = aws_subnet.public[0].id
  iam_instance_profile   = aws_iam_instance_profile.appserv.name
  vpc_security_group_ids = [aws_security_group.appserv.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/cloud-init.appserv-direct.sh.tftpl", {
    vault_provider       = var.vault_provider
    vault_addr           = var.vault_addr
    vault_role_id        = var.vault_role_id
    vault_ca_source      = local.hub_vault_ca_source
    region               = var.region
    name_root            = local.name_root
    mos_version          = var.mos_version
    mos_installer_sha256 = var.mos_installer_sha256
    hub_domain           = var.hub_domain
  }))

  # SSM param must exist before instances launch and fetch the secret_id.
  depends_on = [aws_ssm_parameter.appserv_secret_id]

  tags = { Name = "${local.name_root}-appserv" }

  lifecycle {
    precondition {
      condition     = !local.hub_hashicorp || var.vault_addr != ""
      error_message = "vault_provider = hashicorp requires vault_addr (the https address of your byo Vault; this package never launches one)."
    }
    precondition {
      condition     = local.hub_hashicorp || (var.vault_addr == "" && var.vault_ca_pem == "" && var.vault_role_id == "" && var.vault_secret_id == "")
      error_message = "vault_addr/vault_ca_pem/vault_role_id/vault_secret_id are only for vault_provider = hashicorp — the aws provider uses Secrets Manager with instance roles."
    }
  }
}

# ---------- direct-IP security group additions ----------
# 443/80 open directly (Caddy). Not needed in the ALB path (lb.tf's alb SG
# takes 443 there instead; appserv itself is never internet-facing).
resource "aws_vpc_security_group_ingress_rule" "appserv_https_direct" {
  count             = var.appserv_direct_ip ? 1 : 0
  security_group_id = aws_security_group.appserv.id
  cidr_ipv4         = var.client_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "client HTTPS (Caddy)"
}

# Let's Encrypt HTTP-01 challenge traffic can originate from any of their
# validation servers, not a fixed range — this one rule is intentionally
# broader than client_cidr; it only ever serves the ACME challenge + a
# redirect to 443, nothing app-level.
resource "aws_vpc_security_group_ingress_rule" "appserv_http_acme" {
  count             = var.appserv_direct_ip ? 1 : 0
  security_group_id = aws_security_group.appserv.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "ACME HTTP-01 challenge (Lets Encrypt)"
}

# SRPC 9443 from the client_cidr is NOT opened here — dataserv/gcserv/blockserv
# already reach it via the SG-to-SG rules in security-groups.tf
# (appserv_srpc_from_dataserv etc.), which work regardless of subnet type.
# Nothing else needs to dial appserv's SRPC port directly.

locals {
  # Single source of truth for "how do region services reach appserv's SRPC",
  # used by block-compute.tf and region-compute.tf instead of hardcoding the
  # NLB's dns_name. direct-IP: the Elastic IP. ALB path: the NLB's DNS name
  # (unchanged from before).
  appserv_srpc_addr = var.appserv_direct_ip ? "${aws_eip.appserv[0].public_ip}:9443" : "${aws_lb.appserv_srpc[0].dns_name}:9443"
}
