# Self-hosted region Vault node (single raft peer), separate from the hub Vault.
# Auto-unseals against the REGION CMK. Its service-verifiers must include the
# hub appserv verifier (fan-out done by a separate seed script, not here).
# Provisioned only when region_vault_hosting = self-hosted.

# ---------- region vault node: awskms auto-unseal against the region CMK ----------
resource "aws_iam_role" "region_vault" {
  count              = local.region_self_vault ? 1 : 0
  name               = "mountos-region-vault"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "mountos-region-vault" }
}

data "aws_iam_policy_document" "region_vault_kms" {
  statement {
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.region.arn]
  }
}

resource "aws_iam_role_policy" "region_vault_kms" {
  count  = local.region_self_vault ? 1 : 0
  name   = "mountos-region-vault-kms"
  role   = aws_iam_role.region_vault[0].id
  policy = data.aws_iam_policy_document.region_vault_kms.json
}

# Publish the self-signed TLS CA to SSM so dataserv/blockserv can trust the region Vault.
data "aws_iam_policy_document" "region_vault_ca" {
  statement {
    actions   = ["ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/mountos/region/vault-ca"]
  }
}

resource "aws_iam_role_policy" "region_vault_ca" {
  count  = local.region_self_vault ? 1 : 0
  name   = "mountos-region-vault-ca"
  role   = aws_iam_role.region_vault[0].id
  policy = data.aws_iam_policy_document.region_vault_ca.json
}

resource "aws_iam_instance_profile" "region_vault" {
  count = local.region_self_vault ? 1 : 0
  name  = "mountos-region-vault"
  role  = aws_iam_role.region_vault[0].name
}

# ---------- region vault SG: API 8200 from dataserv, raft 8201 self ----------
resource "aws_security_group" "region_vault" {
  count       = local.region_self_vault ? 1 : 0
  name        = "mountos-region-vault"
  description = "region vault: API 8200 from dataserv, raft 8201 self"
  vpc_id      = local.region_vpc_id
  tags        = { Name = "mountos-region-vault" }
}

resource "aws_vpc_security_group_ingress_rule" "region_vault_api_from_dataserv" {
  count                        = local.region_self_vault ? 1 : 0
  security_group_id            = aws_security_group.region_vault[0].id
  referenced_security_group_id = aws_security_group.dataserv.id
  from_port                    = 8200
  to_port                      = 8200
  ip_protocol                  = "tcp"
  description                  = "Vault API from dataserv"
}

# Raft peer port, reserved for future 3-node HA.
resource "aws_vpc_security_group_ingress_rule" "region_vault_raft_self" {
  count                        = local.region_self_vault ? 1 : 0
  security_group_id            = aws_security_group.region_vault[0].id
  referenced_security_group_id = aws_security_group.region_vault[0].id
  from_port                    = 8201
  to_port                      = 8201
  ip_protocol                  = "tcp"
  description                  = "Vault raft peers"
}

resource "aws_vpc_security_group_egress_rule" "region_vault_all" {
  count             = local.region_self_vault ? 1 : 0
  security_group_id = aws_security_group.region_vault[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "region_vault" {
  count                  = local.region_self_vault ? 1 : 0
  ami                    = local.ami
  instance_type          = var.region_vault_instance_type
  subnet_id              = local.region_subnets[0].id
  iam_instance_profile   = aws_iam_instance_profile.region_vault[0].name
  vpc_security_group_ids = [aws_security_group.region_vault[0].id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = templatefile("${path.module}/region-vault-init.sh.tftpl", {
    kms_key_id = aws_kms_key.region.key_id
    region     = var.region
  })

  tags = { Name = "mountos-region-vault" }
}
