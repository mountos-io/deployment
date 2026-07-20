data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---------- appserv: SSM (hashicorp mode) or Secrets Manager (aws mode) ----------
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

# ---------- cloud-native secret store (vault_provider = aws) ----------
# Instances authenticate to Secrets Manager with their instance role; the
# permission matrix that separate hub/region Vaults used to enforce is carried
# by IAM name scoping instead. The hard rule preserved: appserv can NEVER read
# mountos/api-master (region-only key material), and region services can never
# read mountos/appserv (hub signing key + admin DSN + dashboard HMAC).
# Secret ARNs carry a random 6-char suffix, hence the -?????? matches (exactly
# six, so a hostile mountos/appserv-evil name cannot ride along); the s3creds/
# volcreds path wildcards intentionally cover their dynamic per-volume names.
locals {
  sm_arn_prefix = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret"

  # appserv: read-only, own config + the verifier set.
  appserv_secret_arns = [
    "${local.sm_arn_prefix}:mountos/appserv-??????",
    "${local.sm_arn_prefix}:mountos/service-verifiers-??????",
  ]

  # dataserv + co-located gcserv: own configs, verifiers, api-master, and full
  # CRUD on the per-volume credential paths they own (s3creds/volcreds).
  dataserv_secret_read_arns = [
    "${local.sm_arn_prefix}:mountos/dataserv-??????",
    "${local.sm_arn_prefix}:mountos/gcserv-??????",
    "${local.sm_arn_prefix}:mountos/service-verifiers-??????",
    "${local.sm_arn_prefix}:mountos/api-master-??????",
    "${local.sm_arn_prefix}:mountos/s3creds/*",
    "${local.sm_arn_prefix}:mountos/volcreds/*",
  ]
  dataserv_secret_write_arns = [
    "${local.sm_arn_prefix}:mountos/api-master-??????", # gcserv rotation
    "${local.sm_arn_prefix}:mountos/s3creds/*",
    "${local.sm_arn_prefix}:mountos/volcreds/*",
  ]

  # blockserv: read-only, own config plus verifiers and volume credentials.
  region_worker_secret_arns = [
    "${local.sm_arn_prefix}:mountos/blockserv-??????",
    "${local.sm_arn_prefix}:mountos/service-verifiers-??????",
    "${local.sm_arn_prefix}:mountos/s3creds/*",
    "${local.sm_arn_prefix}:mountos/volcreds/*",
  ]
}

data "aws_iam_policy_document" "appserv_secretstore" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = local.appserv_secret_arns
  }
  # SecretStore.Ping probes with ListSecrets (metadata-only, cannot read values).
  statement {
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "appserv_secretstore" {
  count  = var.vault_provider == "aws" ? 1 : 0
  name   = "mountos-appserv-secretstore"
  role   = aws_iam_role.appserv.id
  policy = data.aws_iam_policy_document.appserv_secretstore.json
}

data "aws_iam_policy_document" "dataserv_secretstore" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = local.dataserv_secret_read_arns
  }
  statement {
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:DeleteSecret",
    ]
    resources = local.dataserv_secret_write_arns
  }
  statement {
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "dataserv_secretstore" {
  count  = var.region_vault_provider == "aws" ? 1 : 0
  name   = "mountos-dataserv-secretstore"
  role   = aws_iam_role.dataserv.id
  policy = data.aws_iam_policy_document.dataserv_secretstore.json
}

data "aws_iam_policy_document" "region_worker_secretstore" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = local.region_worker_secret_arns
  }
  statement {
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "blockserv_secretstore" {
  count  = var.block_enable && var.region_vault_provider == "aws" ? 1 : 0
  name   = "mountos-blockserv-secretstore"
  role   = aws_iam_role.blockserv[0].id
  policy = data.aws_iam_policy_document.region_worker_secretstore.json
}
