# dataserv fleet (+ co-located gcserv). Registers with the hub over SRPC at the
# hub NLB :9443; reaches the region Vault over the network (no KMS on dataserv).

# ---------- dataserv: SSM only; no KMS (reaches region Vault over the network) ----------
resource "aws_iam_role" "dataserv" {
  name               = "${local.name_root}-dataserv"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_root}-dataserv" }
}

resource "aws_iam_role_policy_attachment" "dataserv_ssm" {
  role       = aws_iam_role.dataserv.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "dataserv" {
  name = "${local.name_root}-dataserv"
  role = aws_iam_role.dataserv.name
}

# Read the region Vault AppRole secret_id from SSM SecureString (KMS decrypt via SSM only).
data "aws_iam_policy_document" "dataserv_secret_id" {
  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${local.name_root}/region/vault-secret-id",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${local.name_root}/region/vault-ca",
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

resource "aws_iam_role_policy" "dataserv_secret_id" {
  name   = "${local.name_root}-dataserv-secret-id"
  role   = aws_iam_role.dataserv.id
  policy = data.aws_iam_policy_document.dataserv_secret_id.json
}

resource "aws_launch_template" "dataserv" {
  name_prefix   = "${local.name_root}-dataserv-"
  image_id      = local.ami
  instance_type = var.dataserv_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.dataserv.name
  }

  vpc_security_group_ids = var.gcserv_colocated ? [aws_security_group.dataserv.id, aws_security_group.gcserv.id] : [aws_security_group.dataserv.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  # Raft data volume (ephemeral per instance). On ASG replacement a new node rejoins
  # the quorum and re-syncs from peers; raft state is NOT migrated across replacements.
  # min_healthy 67% keeps quorum during refresh.
  block_device_mappings {
    device_name = "/dev/sdf"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.raft_ebs_gb
      iops                  = var.raft_ebs_iops
      delete_on_termination = true
      encrypted             = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/region-cloud-init.dataserv.sh.tftpl", {
    vault_provider       = var.region_vault_provider
    vault_addr           = var.region_vault_addr
    vault_role_id        = var.region_vault_role_id
    vault_ca_source      = local.region_vault_ca_source
    region               = var.region
    name_root            = local.name_root
    region_cluster_id    = var.region_cluster_id
    srpc_addr            = "${aws_lb.appserv_srpc.dns_name}:9443"
    arena_size           = var.arena_size
    mos_version          = var.mos_version
    mos_installer_sha256 = var.mos_installer_sha256
    gcserv_colocated     = var.gcserv_colocated
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name_root}-dataserv" }
  }

  tags = { Name = "${local.name_root}-dataserv" }

  lifecycle {
    precondition {
      condition     = !local.region_hashicorp || var.region_vault_addr != ""
      error_message = "region_vault_provider = hashicorp requires region_vault_addr (the https address of your byo region Vault; this package never launches one)."
    }
    precondition {
      condition     = local.region_hashicorp || (var.region_vault_addr == "" && var.region_vault_ca_pem == "" && var.region_vault_role_id == "" && var.region_vault_secret_id == "")
      error_message = "region_vault_addr/region_vault_ca_pem/region_vault_role_id/region_vault_secret_id are only for region_vault_provider = hashicorp — the aws provider uses Secrets Manager with instance roles."
    }
  }
}

# health_check_type EC2 (not ELB): dataserv is not behind the hub LBs. Raft quorum
# forms via the 6465 peer SG; instances discover peers via hub registration.
# PUBLIC subnets: dataserv advertises a public IPv4 and is reached directly by
# clients (no proxy). Auto-assigned per instance (ephemeral) — a replaced node
# gets a new one, tolerated by the raft quorum + client-side rediscovery, same
# as any other node-loss/replacement.
resource "aws_autoscaling_group" "dataserv" {
  name_prefix         = "${local.name_root}-dataserv-"
  desired_capacity    = var.dataserv_count
  min_size            = var.dataserv_count
  max_size            = var.dataserv_count
  vpc_zone_identifier = local.region_public_subnets[*].id
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.dataserv.id
    version = aws_launch_template.dataserv.latest_version
  }

  # SSM param must exist before instances launch and fetch the secret_id.
  depends_on = [aws_ssm_parameter.region_secret_id]

  # `make upgrade` (bump mos_version -> apply) rolls the fleet, not just new instances.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 67
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_root}-dataserv"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
