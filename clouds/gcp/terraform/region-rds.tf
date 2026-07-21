# Region DB (mountos_data) on Cloud SQL. Provisioned only when region_db_mode = provision-sql.
# Separate from the hub admin DB per mountOS topology. See rds.tf for the
# manage_master_user_password PARITY GAP note — same caveat applies here.

resource "random_password" "region_db" {
  count            = local.region_provision_sql ? 1 : 0
  length           = 32
  special          = true
  override_special = "-_"
}

resource "google_secret_manager_secret" "region_db_password" {
  count     = local.region_provision_sql ? 1 : 0
  secret_id = "${local.name_root}-region-db-password"
  # replication.auto, not CMEK: see secrets.tf's header comment for why.
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "region_db_password" {
  count       = local.region_provision_sql ? 1 : 0
  secret      = google_secret_manager_secret.region_db_password[0].id
  secret_data = random_password.region_db[0].result
}

# Cloud SQL private IP needs its own reserved peering range per network — the
# region network (dedicated mode) is a SEPARATE network from the hub's, so it
# needs its own service-networking connection, not a shared one.
resource "google_compute_global_address" "region_private_services" {
  count         = local.region_dedicated_vpc ? 1 : 0
  name          = "${local.name_root}-region-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.region[0].id
}

resource "google_service_networking_connection" "region_private_services" {
  count                   = local.region_dedicated_vpc ? 1 : 0
  network                 = google_compute_network.region[0].id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.region_private_services[0].name]
}

resource "google_sql_database_instance" "region" {
  count               = local.region_provision_sql ? 1 : 0
  name                = "${local.name_root}-region"
  database_version    = var.region_db_provider_version
  region              = var.region
  deletion_protection = var.mode == "production"

  settings {
    tier              = var.region_db_tier
    availability_type = var.mode == "production" ? "REGIONAL" : "ZONAL"
    disk_size         = var.region_db_disk_gb
    disk_autoresize   = true

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 14
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = local.region_network
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }

  # No prevent_destroy: see rds.tf's admin resource for why.

  depends_on = [
    google_service_networking_connection.private_services,
    google_service_networking_connection.region_private_services,
  ]
}

resource "google_sql_database" "region" {
  count    = local.region_provision_sql ? 1 : 0
  name     = "mountos_data"
  instance = google_sql_database_instance.region[0].name
}

resource "google_sql_user" "region" {
  count    = local.region_provision_sql ? 1 : 0
  name     = var.region_db_username
  instance = google_sql_database_instance.region[0].name
  password = random_password.region_db[0].result
}

