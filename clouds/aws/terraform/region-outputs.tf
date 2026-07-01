output "region_vault_addr" {
  value = local.region_vault_endpoint
}

# byo mode: the operator's DSN passes straight through. provision-rds mode:
# null — the password is AWS-managed; use region_db_host + region_db_secret_arn
# instead (region-seed.sh fetches the password from Secrets Manager and builds
# the DSN itself, so it never appears in tfstate).
output "region_db_url" {
  value     = local.region_provision_rds ? null : var.region_db_url
  sensitive = true
}

output "region_db_host" {
  value = local.region_provision_rds ? aws_db_instance.region[0].endpoint : null
}

output "region_db_secret_arn" {
  value = local.region_provision_rds ? aws_db_instance.region[0].master_user_secret[0].secret_arn : null
}

output "dataserv_asg" {
  value = aws_autoscaling_group.dataserv.name
}
