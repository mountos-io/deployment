data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---------- vault node: awskms auto-unseal against the hub CMK ----------
resource "aws_iam_role" "vault" {
  count              = local.self_vault ? 1 : 0
  name               = "mountos-vault"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "mountos-vault" }
}

data "aws_iam_policy_document" "vault_kms" {
  statement {
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.hub.arn]
  }
}

resource "aws_iam_role_policy" "vault_kms" {
  count  = local.self_vault ? 1 : 0
  name   = "mountos-vault-kms"
  role   = aws_iam_role.vault[0].id
  policy = data.aws_iam_policy_document.vault_kms.json
}

# Publish the self-signed TLS CA to SSM so appserv can trust Vault.
data "aws_iam_policy_document" "vault_ca" {
  statement {
    actions   = ["ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/mountos/hub/vault-ca"]
  }
}

resource "aws_iam_role_policy" "vault_ca" {
  count  = local.self_vault ? 1 : 0
  name   = "mountos-vault-ca"
  role   = aws_iam_role.vault[0].id
  policy = data.aws_iam_policy_document.vault_ca.json
}

resource "aws_iam_instance_profile" "vault" {
  count = local.self_vault ? 1 : 0
  name  = "mountos-vault"
  role  = aws_iam_role.vault[0].name
}

# ---------- appserv: SSM only; reaches Vault over the network, no KMS ----------
resource "aws_iam_role" "appserv" {
  name               = "mountos-appserv"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "mountos-appserv" }
}

resource "aws_iam_role_policy_attachment" "appserv_ssm" {
  role       = aws_iam_role.appserv.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "appserv" {
  name = "mountos-appserv"
  role = aws_iam_role.appserv.name
}

# Read the Vault AppRole secret_id from SSM SecureString (KMS decrypt via SSM only).
data "aws_iam_policy_document" "appserv_secret_id" {
  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/mountos/appserv/vault-secret-id",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/mountos/hub/vault-ca",
    ]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "appserv_secret_id" {
  name   = "mountos-appserv-secret-id"
  role   = aws_iam_role.appserv.id
  policy = data.aws_iam_policy_document.appserv_secret_id.json
}
