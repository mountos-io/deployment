resource "aws_launch_template" "appserv" {
  name_prefix   = "${local.name_root}-appserv-"
  image_id      = local.ami
  instance_type = var.appserv_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.appserv.name
  }

  vpc_security_group_ids = [aws_security_group.appserv.id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/cloud-init.appserv.sh.tftpl", {
    vault_provider       = var.vault_provider
    vault_addr           = var.vault_addr
    vault_role_id        = var.vault_role_id
    vault_ca_source      = local.hub_vault_ca_source
    region               = var.region
    name_root            = local.name_root
    mos_version          = var.mos_version
    mos_installer_sha256 = var.mos_installer_sha256
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name_root}-appserv" }
  }

  tags = { Name = "${local.name_root}-appserv" }

  lifecycle {
    precondition {
      condition     = !local.hub_hashicorp || var.vault_addr != ""
      error_message = "vault_provider = hashicorp requires vault_addr (the https address of your byo Vault; this package never launches one)."
    }
    precondition {
      condition     = local.hub_hashicorp || (var.vault_addr == "" && var.vault_ca_pem == "" && var.vault_role_id == "" && var.vault_secret_id == "")
      error_message = "vault_addr/vault_ca_pem/vault_role_id/vault_secret_id are only for vault_provider = hashicorp — the aws provider uses Secrets Manager with instance roles."
    }
  }
}

resource "aws_autoscaling_group" "appserv" {
  name_prefix         = "${local.name_root}-appserv-"
  desired_capacity    = var.appserv_count
  min_size            = var.appserv_count
  max_size            = var.appserv_count
  vpc_zone_identifier = aws_subnet.private[*].id
  health_check_type   = "ELB"

  target_group_arns = [
    aws_lb_target_group.appserv_http.arn,
    aws_lb_target_group.appserv_srpc.arn,
  ]

  launch_template {
    id      = aws_launch_template.appserv.id
    version = aws_launch_template.appserv.latest_version
  }

  # SSM param must exist before instances launch and fetch the secret_id.
  depends_on = [aws_ssm_parameter.appserv_secret_id]

  # `make upgrade` (bump mos_version -> apply) rolls the fleet, not just new instances.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_root}-appserv"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
