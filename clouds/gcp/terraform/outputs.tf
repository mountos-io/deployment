locals {
  # Unlike AWS (manage_master_user_password keeps the password out of
  # Terraform entirely), Cloud SQL's password IS a Terraform value here (see
  # rds.tf's PARITY GAP note) — so, unlike AWS, a full DSN CAN be constructed
  # directly, no separate host+secret split needed.
  admin_dsn = local.provision_sql ? "postgresql://${var.db_username}:${random_password.admin_db[0].result}@${google_sql_database_instance.admin[0].private_ip_address}/mountos_admin?sslmode=require" : var.admin_db_url
}

output "hub_url" {
  value = "https://${var.hub_domain}"
}

output "lb_ip" {
  value = google_compute_global_address.appserv.address
}

output "vault_addr" {
  value = local.vault_endpoint
}

output "admin_db_url" {
  value     = local.admin_dsn
  sensitive = true
}

output "project_id" {
  value = var.project_id
}
