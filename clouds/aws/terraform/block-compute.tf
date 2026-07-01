# blockserv data-plane members. Each member is a distinct aws_instance with its
# own BLOCK_VOLUME_ID and its own cache EBS, spread across public subnets/AZs
# (blockserv advertises a public IPv4 — clients reach it directly by IP, no
# proxy). Each member gets a stable Elastic IP (not an ephemeral auto-assigned
# one): unlike the ASG-based fleets, blockserv members are individually
# addressed by a persistent BLOCK_VOLUME_ID and aren't expected to churn via
# rolling replacement, so a stable address avoids unnecessary re-discovery.
# Registers with the hub over SRPC at the hub NLB :9443; reaches the region Vault
# over the network (no KMS). Peers on 9101 across distinct clusters.

# ---------- blockserv IAM: SSM only; no KMS ----------
resource "aws_iam_role" "blockserv" {
  count              = var.block_enable ? 1 : 0
  name               = "mountos-blockserv"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "mountos-blockserv" }
}

resource "aws_iam_role_policy_attachment" "blockserv_ssm" {
  count      = var.block_enable ? 1 : 0
  role       = aws_iam_role.blockserv[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "blockserv" {
  count = var.block_enable ? 1 : 0
  name  = "mountos-blockserv"
  role  = aws_iam_role.blockserv[0].name
}

# Read the region Vault AppRole secret_id from SSM SecureString (KMS decrypt via SSM only).
data "aws_iam_policy_document" "blockserv_secret_id" {
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

resource "aws_iam_role_policy" "blockserv_secret_id" {
  count  = var.block_enable ? 1 : 0
  name   = "mountos-blockserv-secret-id"
  role   = aws_iam_role.blockserv[0].id
  policy = data.aws_iam_policy_document.blockserv_secret_id.json
}

# Separate cache EBS per member, in the member's subnet AZ. Persists independently
# of the instance (delete_on_termination is moot for a detached volume).
resource "aws_ebs_volume" "blockserv_cache" {
  for_each          = local.block_members_map
  availability_zone = local.region_public_subnets[each.value.az_index % length(local.region_public_subnets)].availability_zone
  size              = var.block_cache_gb
  type              = var.block_cache_type
  iops              = var.block_cache_iops
  throughput        = var.block_cache_throughput
  encrypted         = true
  tags              = { Name = "mountos-blockserv-cache-${each.key}" }
}

resource "aws_volume_attachment" "blockserv_cache" {
  for_each    = local.block_members_map
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.blockserv_cache[each.key].id
  instance_id = aws_instance.blockserv[each.key].id
}

# Stable public IP per member (see file header for why this is an EIP, not an
# auto-assigned ephemeral one).
resource "aws_eip" "blockserv" {
  for_each = local.block_members_map
  domain   = "vpc"
  tags     = { Name = "mountos-blockserv-${each.key}" }
}

resource "aws_eip_association" "blockserv" {
  for_each      = local.block_members_map
  instance_id   = aws_instance.blockserv[each.key].id
  allocation_id = aws_eip.blockserv[each.key].id
}

resource "aws_instance" "blockserv" {
  for_each               = local.block_members_map
  ami                    = local.ami
  instance_type          = var.block_instance_type
  subnet_id              = local.region_public_subnets[each.value.az_index % length(local.region_public_subnets)].id
  iam_instance_profile   = aws_iam_instance_profile.blockserv[0].name
  vpc_security_group_ids = [aws_security_group.blockserv.id]

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

  user_data = base64encode(templatefile("${path.module}/block-cloud-init.blockserv.sh.tftpl", {
    vault_addr           = local.region_vault_endpoint
    vault_role_id        = var.region_vault_role_id
    region               = var.region
    region_cluster_id    = var.region_cluster_id
    srpc_addr            = "${aws_lb.appserv_srpc.dns_name}:9443"
    advertise_addr       = aws_eip.blockserv[each.key].public_ip
    block_volume_id      = each.value.block_volume_id
    delete_mode          = var.block_delete_mode
    mos_version          = var.mos_version
    mos_installer_sha256 = var.mos_installer_sha256
  }))

  # SSM param must exist before instances launch and fetch the secret_id.
  depends_on = [aws_ssm_parameter.region_secret_id]

  tags = { Name = "mountos-blockserv-${each.key}" }
}
