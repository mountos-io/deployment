# ---------- vault node: gcpckms auto-unseal against the hub key (kms.tf) ----------
resource "google_service_account" "vault" {
  count        = local.self_vault ? 1 : 0
  account_id   = "mountos-vault"
  display_name = "mountOS hub vault"
}

# Publish the self-signed TLS CA to Secret Manager so appserv can trust Vault.
resource "google_secret_manager_secret_iam_member" "vault_ca_writer" {
  count     = local.self_vault ? 1 : 0
  secret_id = google_secret_manager_secret.hub_vault_ca.id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${google_service_account.vault[0].email}"
}

# ---------- appserv: reaches Vault over the network, no KMS ----------
resource "google_service_account" "appserv" {
  account_id   = "mountos-appserv"
  display_name = "mountOS appserv"
}

resource "google_secret_manager_secret_iam_member" "appserv_secret_id_reader" {
  secret_id = google_secret_manager_secret.appserv_vault_secret_id.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.appserv.email}"
}

resource "google_secret_manager_secret_iam_member" "appserv_vault_ca_reader" {
  secret_id = google_secret_manager_secret.hub_vault_ca.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.appserv.email}"
}
