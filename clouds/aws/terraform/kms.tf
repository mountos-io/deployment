# Per-scope CMKs. Each backs its scope's Vault auto-unseal (and enforces isolation:
# a region node's role can decrypt only the region CMK, never the hub CMK).

locals {
  account_root_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  kms_vault_actions = [
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:GenerateDataKey",
    "kms:ReEncrypt*",
  ]

  # Roles that read region-scoped SSM SecureString params (region_vault_secret_id,
  # region_vault_ca), gated the same way their own aws_iam_role resources are.
  region_secret_reader_arns = compact([
    aws_iam_role.dataserv.arn,
    var.block_enable ? aws_iam_role.blockserv[0].arn : "",
    var.hdfs_enable ? aws_iam_role.hdfsserv[0].arn : "",
    var.s3gateway_enable ? aws_iam_role.s3gatewayserv[0].arn : "",
  ])
}

# Explicit key policy: root retains full administration; the scope's Vault role
# (when self-hosted) gets only unseal-grade crypto. Without this AWS defaults to
# account-wide kms:* for any principal with KMS permissions.
data "aws_iam_policy_document" "hub_key" {
  statement {
    sid       = "RootAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root_arn]
    }
  }
  dynamic "statement" {
    for_each = local.self_vault ? [1] : []
    content {
      sid       = "VaultUse"
      actions   = local.kms_vault_actions
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = [aws_iam_role.vault[0].arn]
      }
    }
  }
  # appserv reads /mountos/appserv/vault-secret-id + /mountos/hub/vault-ca
  # (ssm.tf), SecureString-encrypted with this CMK — decrypt-only, and only
  # reachable via SSM (not a general-purpose KMS grant on this key).
  statement {
    sid       = "SsmSecretRead"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.appserv.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "hub" {
  description             = "mountOS hub vault auto-unseal"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.hub_key.json
  tags                    = { Name = "mountos-hub" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "hub" {
  name          = "alias/mountos-hub"
  target_key_id = aws_kms_key.hub.key_id
}

data "aws_iam_policy_document" "region_key" {
  statement {
    sid       = "RootAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.account_root_arn]
    }
  }
  dynamic "statement" {
    for_each = local.region_self_vault ? [1] : []
    content {
      sid       = "VaultUse"
      actions   = local.kms_vault_actions
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = [aws_iam_role.region_vault[0].arn]
      }
    }
  }
  # dataserv/blockserv/hdfsserv/s3gatewayserv (whichever are enabled) read
  # /mountos/region/vault-secret-id + /mountos/region/vault-ca, SecureString-
  # encrypted with this CMK — decrypt-only, and only reachable via SSM.
  statement {
    sid       = "SsmSecretRead"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = local.region_secret_reader_arns
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "region" {
  description             = "mountOS region vault auto-unseal"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.region_key.json
  tags                    = { Name = "mountos-region" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "region" {
  name          = "alias/mountos-region"
  target_key_id = aws_kms_key.region.key_id
}

output "kms_key_ids" {
  value = {
    hub    = aws_kms_key.hub.key_id
    region = aws_kms_key.region.key_id
  }
}
