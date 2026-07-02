# No DSN output: see outputs.tf's admin_db_host comment. provision-sql: the
# operator builds REGION_DB_URL from region_db_host + region_db_password_secret
# for `make region-bootstrap`. byo: the operator sets REGION_DB_URL directly.
output "region_db_host" {
  value = local.region_provision_sql ? google_sql_database_instance.region[0].private_ip_address : null
}

output "region_db_password_secret" {
  value = local.region_provision_sql ? google_secret_manager_secret.region_db_password[0].secret_id : null
}

output "dataserv_mig" {
  value = google_compute_region_instance_group_manager.dataserv.name
}
