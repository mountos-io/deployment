# AMI for appserv, dataserv, blockserv, and the self-hosted Vault nodes.
# Default: look up the latest Amazon Linux 2023 arm64. Set var.ami_id to PIN a
# specific AMI for reproducible/production rollouts.
variable "ami_id" {
  type        = string
  description = "Pin a specific AMI id. Empty looks up the latest AL2023 arm64."
  default     = ""
}

data "aws_ami" "al2023_arm64" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  ami = var.ami_id != "" ? var.ami_id : data.aws_ami.al2023_arm64[0].id
}
