# hdfsserv fleet: stateless WebHDFS gateway, ASG (no per-instance identity,
# unlike blockserv's per-volume members). Registers with the hub over SRPC at
# the hub NLB :9443; reaches the region Vault over the network (no KMS).

# ---------- hdfsserv IAM: SSM only; no KMS ----------
resource "aws_iam_role" "hdfsserv" {
  count              = var.hdfs_enable ? 1 : 0
  name               = "mountos-hdfsserv"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "mountos-hdfsserv" }
}

resource "aws_iam_role_policy_attachment" "hdfsserv_ssm" {
  count      = var.hdfs_enable ? 1 : 0
  role       = aws_iam_role.hdfsserv[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "hdfsserv" {
  count = var.hdfs_enable ? 1 : 0
  name  = "mountos-hdfsserv"
  role  = aws_iam_role.hdfsserv[0].name
}

# Read the region Vault AppRole secret_id from SSM SecureString (KMS decrypt via SSM only).
data "aws_iam_policy_document" "hdfsserv_secret_id" {
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

resource "aws_iam_role_policy" "hdfsserv_secret_id" {
  count  = var.hdfs_enable ? 1 : 0
  name   = "mountos-hdfsserv-secret-id"
  role   = aws_iam_role.hdfsserv[0].id
  policy = data.aws_iam_policy_document.hdfsserv_secret_id.json
}

resource "aws_launch_template" "hdfsserv" {
  count         = var.hdfs_enable ? 1 : 0
  name_prefix   = "mountos-hdfsserv-"
  image_id      = local.ami
  instance_type = var.hdfs_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.hdfsserv[0].name
  }

  vpc_security_group_ids = [aws_security_group.gateway.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/hdfs-cloud-init.hdfsserv.sh.tftpl", {
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
    tags          = { Name = "mountos-hdfsserv" }
  }

  tags = { Name = "mountos-hdfsserv" }
}

# health_check_type EC2 (not ELB): hdfsserv is not behind the hub LBs. Clients
# reach it directly on 9870 via the gateway security group.
resource "aws_autoscaling_group" "hdfsserv" {
  count               = var.hdfs_enable ? 1 : 0
  name_prefix         = "mountos-hdfsserv-"
  desired_capacity    = var.hdfs_count
  min_size            = var.hdfs_count
  max_size            = var.hdfs_count
  vpc_zone_identifier = local.region_subnets[*].id
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.hdfsserv[0].id
    version = aws_launch_template.hdfsserv[0].latest_version
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
    value               = "mountos-hdfsserv"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
