output "hub_url" {
  value = "https://${var.hub_domain}"
}

output "alb_dns" {
  value = aws_lb.appserv.dns_name
}

output "nlb_dns" {
  value = aws_lb.appserv_srpc.dns_name
}

# No vault_addr output: aws provider needs none (Secrets Manager, instance
# roles); hashicorp provider's address is the operator-supplied var.vault_addr.

# No DSN output: a DSN is never a Terraform value (it would land in tfstate).
# provision-rds: seed-vault.sh builds it from admin_db_host + admin_db_secret_arn.
# byo: the operator sets ADMIN_DB_URL in answers.env for the seed step.
output "admin_db_host" {
  value = local.provision_rds ? aws_db_instance.admin[0].endpoint : null
}

output "admin_db_secret_arn" {
  value = local.provision_rds ? aws_db_instance.admin[0].master_user_secret[0].secret_arn : null
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
