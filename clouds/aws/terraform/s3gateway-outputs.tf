output "s3gatewayserv_instances" {
  value = var.s3gateway_enable ? aws_autoscaling_group.s3gatewayserv[0].name : null
}
