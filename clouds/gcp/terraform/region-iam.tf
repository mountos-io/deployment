# One service account per region service (dataserv/gcserv co-located,
# blockserv, hdfsserv+s3gatewayserv share the "gateway" tier the same way they
# share a firewall tag) — blast-radius isolation, matching the AWS module's
# per-service IAM role even where services share a security group/tag. All
# read the same region Vault CA + AppRole secret_id (same region AppRole).

resource "google_service_account" "dataserv" {
  account_id   = "mountos-dataserv"
  display_name = "mountOS dataserv/gcserv"
}

resource "google_secret_manager_secret_iam_member" "dataserv_secret_id_reader" {
  secret_id = google_secret_manager_secret.region_vault_secret_id.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.dataserv.email}"
}

resource "google_secret_manager_secret_iam_member" "dataserv_vault_ca_reader" {
  secret_id = google_secret_manager_secret.region_vault_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.dataserv.email}"
}

resource "google_service_account" "blockserv" {
  count        = var.block_enable ? 1 : 0
  account_id   = "mountos-blockserv"
  display_name = "mountOS blockserv"
}

resource "google_secret_manager_secret_iam_member" "blockserv_secret_id_reader" {
  count     = var.block_enable ? 1 : 0
  secret_id = google_secret_manager_secret.region_vault_secret_id.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.blockserv[0].email}"
}

resource "google_secret_manager_secret_iam_member" "blockserv_vault_ca_reader" {
  count     = var.block_enable ? 1 : 0
  secret_id = google_secret_manager_secret.region_vault_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.blockserv[0].email}"
}

resource "google_service_account" "hdfsserv" {
  count        = var.hdfs_enable ? 1 : 0
  account_id   = "mountos-hdfsserv"
  display_name = "mountOS hdfsserv"
}

resource "google_secret_manager_secret_iam_member" "hdfsserv_secret_id_reader" {
  count     = var.hdfs_enable ? 1 : 0
  secret_id = google_secret_manager_secret.region_vault_secret_id.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.hdfsserv[0].email}"
}

resource "google_secret_manager_secret_iam_member" "hdfsserv_vault_ca_reader" {
  count     = var.hdfs_enable ? 1 : 0
  secret_id = google_secret_manager_secret.region_vault_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.hdfsserv[0].email}"
}

resource "google_service_account" "s3gatewayserv" {
  count        = var.s3gateway_enable ? 1 : 0
  account_id   = "mountos-s3gatewayserv"
  display_name = "mountOS s3gatewayserv"
}

resource "google_secret_manager_secret_iam_member" "s3gatewayserv_secret_id_reader" {
  count     = var.s3gateway_enable ? 1 : 0
  secret_id = google_secret_manager_secret.region_vault_secret_id.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.s3gatewayserv[0].email}"
}

resource "google_secret_manager_secret_iam_member" "s3gatewayserv_vault_ca_reader" {
  count     = var.s3gateway_enable ? 1 : 0
  secret_id = google_secret_manager_secret.region_vault_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.s3gatewayserv[0].email}"
}
