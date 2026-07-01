# s3gatewayserv fleet: stateless S3 REST gateway, ASG (no per-instance identity,
# unlike blockserv's per-volume members). Registers with the hub over SRPC at
# the hub NLB :9443; reaches the region Vault over the network (no KMS).

# ---------- s3gatewayserv IAM: SSM only; no KMS ----------
resource "aws_iam_role" "s3gatewayserv" {
  count              = var.s3gateway_enable ? 1 : 0
  name               = "mountos-s3gatewayserv"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "mountos-s3gatewayserv" }
}

resource "aws_iam_role_policy_attachment" "s3gatewayserv_ssm" {
  count      = var.s3gateway_enable ? 1 : 0
  role       = aws_iam_role.s3gatewayserv[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "s3gatewayserv" {
  count = var.s3gateway_enable ? 1 : 0
  name  = "mountos-s3gatewayserv"
  role  = aws_iam_role.s3gatewayserv[0].name
}

# Read the region Vault AppRole secret_id from SSM SecureString (KMS decrypt via SSM only).
data "aws_iam_policy_document" "s3gatewayserv_secret_id" {
  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/mountos/region/vault-secret-id",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/mountos/region/vault-ca",
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

resource "aws_iam_role_policy" "s3gatewayserv_secret_id" {
  count  = var.s3gateway_enable ? 1 : 0
  name   = "mountos-s3gatewayserv-secret-id"
  role   = aws_iam_role.s3gatewayserv[0].id
  policy = data.aws_iam_policy_document.s3gatewayserv_secret_id.json
}

resource "aws_launch_template" "s3gatewayserv" {
  count         = var.s3gateway_enable ? 1 : 0
  name_prefix   = "mountos-s3gatewayserv-"
  image_id      = local.ami
  instance_type = var.s3gateway_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.s3gatewayserv[0].name
  }

  vpc_security_group_ids = [aws_security_group.gateway.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/s3gateway-cloud-init.s3gatewayserv.sh.tftpl", {
    vault_addr           = local.region_vault_endpoint
    vault_role_id        = var.region_vault_role_id
    region               = var.region
    region_cluster_id    = var.region_cluster_id
    srpc_addr            = "${aws_lb.appserv_srpc.dns_name}:9443"
    mos_version          = var.mos_version
    mos_installer_sha256 = var.mos_installer_sha256
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "mountos-s3gatewayserv" }
  }

  tags = { Name = "mountos-s3gatewayserv" }
}

# health_check_type EC2 (not ELB): s3gatewayserv is not behind the hub LBs.
# Clients reach it directly on 8484 via the gateway security group.
resource "aws_autoscaling_group" "s3gatewayserv" {
  count               = var.s3gateway_enable ? 1 : 0
  name_prefix         = "mountos-s3gatewayserv-"
  desired_capacity    = var.s3gateway_count
  min_size            = var.s3gateway_count
  max_size            = var.s3gateway_count
  vpc_zone_identifier = aws_subnet.private[*].id
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.s3gatewayserv[0].id
    version = aws_launch_template.s3gatewayserv[0].latest_version
  }

  # SSM param must exist before instances launch and fetch the secret_id.
  depends_on = [aws_ssm_parameter.region_secret_id]

  # `make upgrade` (bump mos_version -> apply) rolls the fleet.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 67
    }
  }

  tag {
    key                 = "Name"
    value               = "mountos-s3gatewayserv"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
