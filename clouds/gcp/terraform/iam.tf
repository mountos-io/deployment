# ---------- appserv: reaches the secret store over the network, no KMS ----------
# account_id has a 6-30 char total limit; a long resource_prefix could push
# "<name_root>-appserv" over it.
resource "google_service_account" "appserv" {
  account_id   = "${local.name_root}-appserv"
  display_name = "mountOS appserv"
}

# byo Vault (vault_provider = hashicorp): read the AppRole secret_id + private
# CA that Terraform publishes to Secret Manager (secrets.tf).
resource "google_secret_manager_secret_iam_member" "appserv_secret_id_reader" {
  count     = local.hub_hashicorp ? 1 : 0
  secret_id = google_secret_manager_secret.appserv_vault_secret_id[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.appserv.email}"
}

resource "google_secret_manager_secret_iam_member" "appserv_vault_ca_reader" {
  count     = local.hub_hashicorp && var.vault_ca_pem != "" ? 1 : 0
  secret_id = google_secret_manager_secret.hub_vault_ca[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.appserv.email}"
}

# ---------- cloud-native secret store (vault_provider = gcp) ----------
# Instances authenticate to Secret Manager with their instance service
# account; the permission matrix that separate hub/region Vaults used to
# enforce is carried by per-secret IAM instead. The hard rule preserved:
# appserv can NEVER read mountos__api-master (region-only key material), and
# region services can never read mountos__appserv (hub signing key + admin
# DSN + dashboard HMAC).

# appserv: read-only, own config + the verifier set.
resource "google_secret_manager_secret_iam_member" "appserv_own_reader" {
  count     = local.hub_gcp ? 1 : 0
  secret_id = google_secret_manager_secret.appserv_config[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.appserv.email}"
}

resource "google_secret_manager_secret_iam_member" "appserv_verifiers_reader" {
  count     = local.hub_gcp ? 1 : 0
  secret_id = google_secret_manager_secret.service_verifiers[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.appserv.email}"
}

# SecretStore.Ping probes with ListSecrets; version reads also list version
# metadata. roles/secretmanager.viewer is metadata-only (names, labels, version
# states — never payloads), same trust level as the AWS module's
# secretsmanager:ListSecrets on *.
resource "google_project_iam_member" "appserv_secret_viewer" {
  count   = local.hub_gcp ? 1 : 0
  project = var.project_id
  role    = "roles/secretmanager.viewer"
  member  = "serviceAccount:${google_service_account.appserv.email}"
}
