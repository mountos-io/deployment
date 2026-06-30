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

output "admin_db_url" {
  value     = local.admin_dsn
  sensitive = true
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
