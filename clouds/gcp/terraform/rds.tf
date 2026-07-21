# Admin DB (mountos_admin) on Cloud SQL. Provisioned only when admin_db_mode = provision-sql.
#
# PARITY GAP vs AWS: RDS has manage_master_user_password (AWS-managed, rotated,
# NEVER a Terraform value). Cloud SQL has no equivalent — there is no "let GCP
# generate and own the password" flag. The closest approximation is generating
# it with the random_password resource and storing it in Secret Manager, but
# unlike AWS this DOES make the password a Terraform value (present in tfstate,
# protected only by state encryption/access control). This is a real,
# documented gap, not silently claimed as equivalent.
resource "random_password" "admin_db" {
  count            = local.provision_sql ? 1 : 0
  length           = 32
  special          = true
  override_special = "-_"
}

resource "google_secret_manager_secret" "admin_db_password" {
  count     = local.provision_sql ? 1 : 0
  secret_id = "${local.name_root}-admin-db-password"
  # replication.auto, not CMEK: see secrets.tf's header comment for why.
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "admin_db_password" {
  count       = local.provision_sql ? 1 : 0
  secret      = google_secret_manager_secret.admin_db_password[0].id
  secret_data = random_password.admin_db[0].result
}

resource "google_sql_database_instance" "admin" {
  count               = local.provision_sql ? 1 : 0
  name                = "${local.name_root}-admin"
  database_version    = var.admin_db_provider_version
  region              = var.region
  deletion_protection = var.mode == "production"

  settings {
    tier              = var.db_tier
    availability_type = var.mode == "production" ? "REGIONAL" : "ZONAL"
    disk_size         = var.db_disk_gb
    disk_autoresize   = true

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 14
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.id
      # Server-side TLS enforcement: bootstrap DSN construction already sets
      # sslmode=require, but that's client-side only.
      ssl_mode = "ENCRYPTED_ONLY"
    }
  }

  # No prevent_destroy: deletion_protection (above) is the real safety net
  # and is correctly mode-gated to production only. prevent_destroy is a
  # Terraform meta-argument that can't take a variable, so it would block
  # dev/staging teardown too if set unconditionally.

  depends_on = [google_service_networking_connection.private_services]
}

resource "google_sql_database" "admin" {
  count    = local.provision_sql ? 1 : 0
  name     = "mountos_admin"
  instance = google_sql_database_instance.admin[0].name
}

resource "google_sql_user" "admin" {
  count    = local.provision_sql ? 1 : 0
  name     = var.db_username
  instance = google_sql_database_instance.admin[0].name
  password = random_password.admin_db[0].result
}

# Cloud SQL private IP requires a VPC peering range reserved for Google's
# managed services (shared by admin + region SQL instances).
resource "google_compute_global_address" "private_services" {
  name          = "${local.name_root}-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
}
