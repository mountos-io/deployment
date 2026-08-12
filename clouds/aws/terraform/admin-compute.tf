# mountos-admin-client, optional (var.admin_client_enabled). Single direct-IP
# instance — own Elastic IP, own public subnet, own domain (admin_domain, NOT
# hub_domain — separate WebAuthn origin). Caddy terminates a real Let's
# Encrypt cert and reverse-proxies to the Bun/Node gateway on 127.0.0.1:3001
# (plain HTTP internally — same shape as appserv-direct.tf's Caddy, minus the
# re-encrypt hop since this gateway has no TLS of its own to re-encrypt to).
# Source is public (github.com/mountos-io/mountos-admin-client) — cloned and
# built on the instance, not shipped as a prebuilt artifact (none exists yet).

resource "aws_security_group" "admin_client" {
  count       = var.admin_client_enabled ? 1 : 0
  name        = "${local.name_root}-admin-client"
  description = "admin-client: public HTTPS (Caddy) + ACME"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name_root}-admin-client" }
}

resource "aws_vpc_security_group_ingress_rule" "admin_client_https" {
  count             = var.admin_client_enabled ? 1 : 0
  security_group_id = aws_security_group.admin_client[0].id
  cidr_ipv4         = var.client_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "operator HTTPS (Caddy)"
}

# See appserv-direct.tf's identical rule for why this is 0.0.0.0/0.
resource "aws_vpc_security_group_ingress_rule" "admin_client_http_acme" {
  count             = var.admin_client_enabled ? 1 : 0
  security_group_id = aws_security_group.admin_client[0].id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "ACME HTTP-01 challenge (Lets Encrypt)"
}

resource "aws_vpc_security_group_egress_rule" "admin_client_all" {
  count             = var.admin_client_enabled ? 1 : 0
  security_group_id = aws_security_group.admin_client[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- IAM: SSM (session manager) + own Secrets Manager scope (see iam.tf) ----------
resource "aws_iam_role" "admin_client" {
  count              = var.admin_client_enabled ? 1 : 0
  name               = "${local.name_root}-admin-client"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_root}-admin-client" }
}

resource "aws_iam_role_policy_attachment" "admin_client_ssm" {
  count      = var.admin_client_enabled ? 1 : 0
  role       = aws_iam_role.admin_client[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "admin_client" {
  count = var.admin_client_enabled ? 1 : 0
  name  = "${local.name_root}-admin-client"
  role  = aws_iam_role.admin_client[0].name
}

resource "aws_eip" "admin_client" {
  count  = var.admin_client_enabled ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.name_root}-admin-client" }
}

resource "aws_eip_association" "admin_client" {
  count         = var.admin_client_enabled ? 1 : 0
  instance_id   = aws_instance.admin_client[0].id
  allocation_id = aws_eip.admin_client[0].id
}

resource "aws_instance" "admin_client" {
  count                  = var.admin_client_enabled ? 1 : 0
  ami                    = local.ami
  instance_type          = var.admin_client_instance_type
  subnet_id              = aws_subnet.public[0].id
  iam_instance_profile   = aws_iam_instance_profile.admin_client[0].name
  vpc_security_group_ids = [aws_security_group.admin_client[0].id]

  root_block_device {
    volume_type = "gp3"
    # 30, not 20: the AL2023 arm64 AMI's root snapshot is 30GB — a smaller
    # volume than the source snapshot is rejected at launch.
    volume_size = 30
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/cloud-init.admin.sh.tftpl", {
    region             = var.region
    name_root          = local.name_root
    admin_domain       = var.admin_domain
    hub_domain         = var.hub_domain
    appserv_private_ip = var.appserv_direct_ip ? aws_instance.appserv_direct[0].private_ip : ""
  }))

  tags = { Name = "${local.name_root}-admin-client" }

  lifecycle {
    precondition {
      condition     = var.vault_provider == "aws"
      error_message = "admin_client_enabled currently only supports vault_provider = aws (Secrets Manager) — the hashicorp path isn't wired for the admin-client secret yet."
    }
  }
}
