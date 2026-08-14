# Disposable mount-test client (var.mount_client_enabled, default false).
#
# DELIBERATELY IN THE ACCOUNT'S DEFAULT VPC, NOT THE DEMO VPC. A real user
# mounts from outside our network: discovery hands the client dataserv's
# PUBLIC address, and an instance inside the demo VPC cannot reliably reach a
# VPC-mate's public IP (AWS hairpin limitation). Putting the tester in the
# default VPC makes it genuinely external, so it exercises the same path a
# customer does. Placing it in the demo VPC would only work via
# INTERNAL_PREFER_PRIVATE_DISCOVERY, i.e. testing a path no real user takes.
#
# Intended lifecycle is create-test-destroy: flip mount_client_enabled on, run
# the mount, flip it off. Nothing here holds state worth keeping.
#
# NO CREDENTIALS ARE BAKED IN. The volume access key pair is supplied at mount
# time (operator's local profile / SSM send-command), never through user_data
# or tfvars, so it never lands in tfstate or instance metadata.

variable "mount_client_enabled" {
  type        = bool
  description = "Launch the disposable mount-test client in the DEFAULT VPC. Off by default; turn on only while actively testing a mount."
  default     = false
}

variable "mount_client_instance_type" {
  type        = string
  description = "Instance type for the mount-test client. Tiny on purpose: it only runs the mountos client."
  default     = "t4g.small"
}

data "aws_vpc" "default" {
  count   = var.mount_client_enabled ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.mount_client_enabled ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

resource "aws_security_group" "mount_client" {
  count       = var.mount_client_enabled ? 1 : 0
  name        = "${local.name_root}-mount-client"
  description = "mount-test client: egress only (reaches hub/dataserv over the public internet)"
  vpc_id      = data.aws_vpc.default[0].id
  tags        = { Name = "${local.name_root}-mount-client" }
}

# Egress only. Nothing dials IN to a mount client — it is a pure consumer, and
# access is via SSM Session Manager (no SSH, no inbound rules, no key pair).
resource "aws_vpc_security_group_egress_rule" "mount_client_all" {
  count             = var.mount_client_enabled ? 1 : 0
  security_group_id = aws_security_group.mount_client[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "mount_client" {
  count              = var.mount_client_enabled ? 1 : 0
  name               = "${local.name_root}-mount-client"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name_root}-mount-client" }
}

# SSM only — this node needs no AWS API access of its own. It talks to mountOS
# over the public internet with the volume access key, exactly like a customer.
resource "aws_iam_role_policy_attachment" "mount_client_ssm" {
  count      = var.mount_client_enabled ? 1 : 0
  role       = aws_iam_role.mount_client[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Optional: let the client fetch its own volume credentials from Secrets Manager
# at mount time, instead of an operator pasting them into every new instance.
#
# This exists because the client is DISPOSABLE. Terminating and recreating it is
# the normal way to change its size or start clean, and each new instance
# otherwise arrives with an empty credentials stub. Secrets Manager is the right
# channel rather than instance user-data or an SSM send-command: user-data is
# readable from inside the instance forever and is stored with the instance,
# and send-command parameters are recorded VERBATIM in CloudTrail. A
# GetSecretValue response is redacted there.
#
# Still a volume access key, not an operator credential: it reaches exactly one
# volume and nothing in the control plane. Leave the variable empty and the
# grant is not created at all, which keeps the default posture of a client that
# holds no AWS permissions beyond SSM.
variable "mount_client_credentials_secret_arn" {
  type        = string
  description = "ARN of a Secrets Manager secret holding the client's mountOS profile (access key id, secret, discovery URL). Empty disables the grant; credentials are then supplied by the operator at mount time."
  default     = ""
}

data "aws_iam_policy_document" "mount_client_secret" {
  count = var.mount_client_enabled && var.mount_client_credentials_secret_arn != "" ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.mount_client_credentials_secret_arn]
  }
}

resource "aws_iam_role_policy" "mount_client_secret" {
  count  = var.mount_client_enabled && var.mount_client_credentials_secret_arn != "" ? 1 : 0
  name   = "${local.name_root}-mount-client-secret"
  role   = aws_iam_role.mount_client[0].id
  policy = data.aws_iam_policy_document.mount_client_secret[0].json
}

resource "aws_iam_instance_profile" "mount_client" {
  count = var.mount_client_enabled ? 1 : 0
  name  = "${local.name_root}-mount-client"
  role  = aws_iam_role.mount_client[0].name
}

resource "aws_instance" "mount_client" {
  count                       = var.mount_client_enabled ? 1 : 0
  ami                         = local.ami
  instance_type               = var.mount_client_instance_type
  subnet_id                   = data.aws_subnets.default[0].ids[0]
  iam_instance_profile        = aws_iam_instance_profile.mount_client[0].name
  vpc_security_group_ids      = [aws_security_group.mount_client[0].id]
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    # 30, not less: the AL2023 arm64 AMI's root snapshot is 30GB and a smaller
    # volume than the source snapshot is rejected at launch.
    volume_size = 30
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/cloud-init.mount-client.sh.tftpl", {
    mos_version          = var.mos_version
    mos_installer_sha256 = var.mos_installer_sha256
  }))

  tags = { Name = "${local.name_root}-mount-client" }
}

output "mount_client_instance_id" {
  description = "Instance ID of the mount-test client (SSM target); null when disabled."
  value       = var.mount_client_enabled ? aws_instance.mount_client[0].id : null
}

output "mount_client_public_ip" {
  description = "Public IP of the mount-test client; null when disabled."
  value       = var.mount_client_enabled ? aws_instance.mount_client[0].public_ip : null
}
