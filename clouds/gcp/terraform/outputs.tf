output "hub_url" {
  value = "https://${var.hub_domain}"
}

output "lb_ip" {
  value = google_compute_global_address.appserv.address
}

# No DSN output: a DSN is never a Terraform value (it would land in tfstate —
# and it already does via random_password, see rds.tf's PARITY GAP note; this
# at least keeps it out of the outputs). provision-sql: the operator builds
# ADMIN_DB_URL from admin_db_host + the admin_db_password_secret secret
# (`gcloud secrets versions access latest --secret=<name>`) for `make bootstrap`.
# byo: the operator sets ADMIN_DB_URL in answers.env for the seed step.
output "admin_db_host" {
  value = local.provision_sql ? google_sql_database_instance.admin[0].private_ip_address : null
}

output "admin_db_password_secret" {
  value = local.provision_sql ? google_secret_manager_secret.admin_db_password[0].secret_id : null
}

output "project_id" {
  value = var.project_id
}
