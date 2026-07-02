# No region_vault_addr output: aws provider needs none (Secrets Manager);
# hashicorp provider's address is the operator-supplied var.region_vault_addr.

# No DSN output: a DSN is never a Terraform value (it would land in tfstate).
# provision-rds: region-seed.sh builds it from region_db_host + region_db_secret_arn.
# byo: the operator sets REGION_DB_URL in the region-seed environment.
output "region_db_host" {
  value = local.region_provision_rds ? aws_db_instance.region[0].endpoint : null
}

output "region_db_secret_arn" {
  value = local.region_provision_rds ? aws_db_instance.region[0].master_user_secret[0].secret_arn : null
}

output "dataserv_asg" {
  value = aws_autoscaling_group.dataserv.name
}
