# Self-hosted Vault node (single raft peer). Provisioned only when vault_hosting = self-hosted.
# HA: scale to 3 raft peers later (see vault-init.sh.tftpl note).
resource "aws_security_group" "vault" {
  count       = local.self_vault ? 1 : 0
  name        = "mountos-vault"
  description = "vault: API 8200 from appserv, raft 8201 self"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "mountos-vault" }
}

resource "aws_vpc_security_group_ingress_rule" "vault_api_from_appserv" {
  count                        = local.self_vault ? 1 : 0
  security_group_id            = aws_security_group.vault[0].id
  referenced_security_group_id = aws_security_group.appserv.id
  from_port                    = 8200
  to_port                      = 8200
  ip_protocol                  = "tcp"
  description                  = "Vault API from appserv"
}

# Raft peer port, reserved for future 3-node HA.
resource "aws_vpc_security_group_ingress_rule" "vault_raft_self" {
  count                        = local.self_vault ? 1 : 0
  security_group_id            = aws_security_group.vault[0].id
  referenced_security_group_id = aws_security_group.vault[0].id
  from_port                    = 8201
  to_port                      = 8201
  ip_protocol                  = "tcp"
  description                  = "Vault raft peers"
}

resource "aws_vpc_security_group_egress_rule" "vault_all" {
  count             = local.self_vault ? 1 : 0
  security_group_id = aws_security_group.vault[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "vault" {
  count                  = local.self_vault ? 1 : 0
  ami                    = local.ami
  instance_type          = var.vault_instance_type
  subnet_id              = aws_subnet.private[0].id
  iam_instance_profile   = aws_iam_instance_profile.vault[0].name
  vpc_security_group_ids = [aws_security_group.vault[0].id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = templatefile("${path.module}/vault-init.sh.tftpl", {
    kms_key_id = aws_kms_key.hub.key_id
    region     = var.region
  })

  tags = { Name = "mountos-vault" }
}
