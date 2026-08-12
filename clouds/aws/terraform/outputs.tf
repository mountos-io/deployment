output "hub_url" {
  value = "https://${var.hub_domain}"
}

# ALB path only. direct-IP mode: see appserv_public_ip below instead — point
# hub_domain at it with a plain A record, no alias target needed.
output "alb_dns" {
  value = var.appserv_direct_ip ? null : aws_lb.appserv[0].dns_name
}

output "nlb_dns" {
  value = var.appserv_direct_ip ? null : aws_lb.appserv_srpc[0].dns_name
}

# direct-IP mode only. Point hub_domain's A record at this.
output "appserv_public_ip" {
  value = var.appserv_direct_ip ? aws_eip.appserv[0].public_ip : null
}

# admin_client_enabled only. Point admin_domain's A record at this.
output "admin_client_public_ip" {
  value = var.admin_client_enabled ? aws_eip.admin_client[0].public_ip : null
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
