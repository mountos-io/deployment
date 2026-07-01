output "hub_url" {
  value = "https://${var.hub_domain}"
}

output "alb_dns" {
  value = aws_lb.appserv.dns_name
}

output "nlb_dns" {
  value = aws_lb.appserv_srpc.dns_name
}

output "vault_addr" {
  value = local.vault_endpoint
}

# byo mode: the operator's DSN passes straight through. provision-rds mode:
# null — the password is AWS-managed; use admin_db_host + admin_db_secret_arn
# instead (seed-vault.sh fetches the password from Secrets Manager and builds
# the DSN itself, so it never appears in tfstate).
output "admin_db_url" {
  value     = local.provision_rds ? null : var.admin_db_url
  sensitive = true
}

output "admin_db_host" {
  value = local.provision_rds ? aws_db_instance.admin[0].endpoint : null
}

output "admin_db_secret_arn" {
  value = local.provision_rds ? aws_db_instance.admin[0].master_user_secret[0].secret_arn : null
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
