locals {
  # Unlike AWS (manage_master_user_password keeps the password out of
  # Terraform entirely), Postgres Flexible Server's password IS a Terraform
  # value here (see rds.tf's PARITY GAP note) — so, unlike AWS, a full DSN CAN
  # be constructed directly, no separate host+secret split needed.
  admin_dsn = local.provision_pg ? "postgresql://${var.db_username}:${random_password.admin_db[0].result}@${azurerm_postgresql_flexible_server.admin[0].fqdn}/mountos_admin?sslmode=require" : var.admin_db_url
}

output "hub_url" {
  value = "https://${var.hub_domain}"
}

output "lb_ip" {
  value = azurerm_public_ip.appgw.ip_address
}

output "vault_addr" {
  value = local.vault_endpoint
}

output "admin_db_url" {
  value     = local.admin_dsn
  sensitive = true
}

output "resource_group" {
  value = azurerm_resource_group.main.name
}
