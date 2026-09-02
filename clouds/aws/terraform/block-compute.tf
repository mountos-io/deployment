# blockserv data-plane members. Each member is a distinct aws_instance with its
# own BLOCK_VOLUME_ID and its own cache EBS, spread across public subnets/AZs
# (blockserv advertises a public IPv4 — clients reach it directly by IP, no
# proxy). Each member gets a stable Elastic IP (not an ephemeral auto-assigned
# one): unlike the ASG-based fleets, blockserv members are individually
# addressed by a persistent BLOCK_VOLUME_ID and aren't expected to churn via
# rolling replacement, so a stable address avoids unnecessary re-discovery.
# Registers with the hub over SRPC at the hub NLB :9443; reaches the region Vault
# over the network (no KMS). Peers with its copyset partner on 9101, region-wide.

# ---------- blockserv IAM: SSM only; no KMS ----------
resource "aws_iam_role" "blockserv" {
  count              = var.block_enable ? 1 : 0
  name               = "${local.name_root}-blockserv"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_root}-blockserv" }
}

resource "aws_iam_role_policy_attachment" "blockserv_ssm" {
  count      = var.block_enable ? 1 : 0
  role       = aws_iam_role.blockserv[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "blockserv" {
  count = var.block_enable ? 1 : 0
  name  = "${local.name_root}-blockserv"
  role  = aws_iam_role.blockserv[0].name
}

# Read the region Vault AppRole secret_id from SSM SecureString (KMS decrypt via SSM only).
data "aws_iam_policy_document" "blockserv_secret_id" {
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

resource "aws_iam_role_policy" "blockserv_secret_id" {
  count  = var.block_enable ? 1 : 0
  name   = "${local.name_root}-blockserv-secret-id"
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
  tags              = { Name = "${local.name_root}-blockserv-cache-${each.key}" }
}

resource "aws_volume_attachment" "blockserv_cache" {
  for_each    = local.block_members_map
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.blockserv_cache[each.key].id
  instance_id = aws_instance.blockserv[each.key].id
}

# Stable public IP per member (see file header for why this is the default), for
# members with use_eip = true. A member with use_eip = false gets the subnet's
# auto-assigned ephemeral public IP instead (associate_public_ip_address below) -
# each EIP counts against the account's quota, so this is the escape hatch for a
# member added past it rather than requesting an increase every time.
resource "aws_eip" "blockserv" {
  for_each = { for k, m in local.block_members_map : k => m if m.use_eip }
  domain   = "vpc"
  tags     = { Name = "${local.name_root}-blockserv-${each.key}" }
}

resource "aws_eip_association" "blockserv" {
  for_each      = aws_eip.blockserv
  instance_id   = aws_instance.blockserv[each.key].id
  allocation_id = each.value.id
}

resource "aws_instance" "blockserv" {
  for_each               = local.block_members_map
  ami                    = local.ami
  instance_type          = var.block_instance_type
  subnet_id              = local.region_public_subnets[each.value.az_index % length(local.region_public_subnets)].id
  iam_instance_profile   = aws_iam_instance_profile.blockserv[0].name
  vpc_security_group_ids = [aws_security_group.blockserv.id]
  # EIP members: leave unset (the EIP association below covers it). Ephemeral
  # members: explicit, since this is their only public address.
  associate_public_ip_address = each.value.use_eip ? null : true

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
    vault_provider    = var.region_vault_provider
    vault_addr        = var.region_vault_addr
    vault_role_id     = var.region_vault_role_id
    vault_ca_source   = local.region_vault_ca_source
    region            = var.region
    name_root         = local.name_root
    resource_prefix   = var.resource_prefix
    region_cluster_id = var.region_cluster_id
    srpc_addr         = local.appserv_srpc_addr
    use_eip           = each.value.use_eip
    # EIP members: the known allocated address, to wait for IMDS to agree with it
    # (see the template's own comment for why). Ephemeral members: nothing to wait
    # for, IMDS's own public-ipv4 is authoritative the moment it appears.
    advertise_addr       = each.value.use_eip ? aws_eip.blockserv[each.key].public_ip : ""
    block_volume_id      = each.value.block_volume_id
    delete_mode          = var.block_delete_mode
    mos_version          = var.mos_version
    mos_installer_sha256 = var.mos_installer_sha256
  }))

  # SSM param must exist before instances launch and fetch the secret_id.
  depends_on = [aws_ssm_parameter.region_secret_id]

  tags = { Name = "${local.name_root}-blockserv-${each.key}" }

  lifecycle {
    # user_data only runs once, at first boot; AWS never re-executes it on a
    # running instance from a Terraform update. So an unrelated template edit
    # (e.g. this file's own use_eip conditional) would otherwise show a no-op
    # diff on every ALREADY-RUNNING member every time the shared template
    # changes at all, even members whose own rendered content didn't actually
    # change in any way that matters. Ignore it here; a deliberate content
    # change that must actually take effect needs a real instance replacement
    # anyway (taint, or a change to a force-replace attribute like ami).
    ignore_changes = [user_data]
  }
}
