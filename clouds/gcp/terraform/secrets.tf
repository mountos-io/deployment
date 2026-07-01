# Secret Manager containers. The vault-ca secrets hold NO terraform-managed
# version — the Vault instance publishes its self-signed CA as a version at
# boot (see vault-init.sh.tftpl). The secret_id secrets get a terraform-managed
# version only when the corresponding var is set (mirrors AWS's SSM
# SecureString pattern — absent on a first apply before the seed runs; cloud-init
# tolerates that).
#
# replication.auto (Google-default encryption), not customer_managed_encryption:
# CMEK here would need the Secret Manager service agent to hold decrypt on the
# CMK, and that agent is NOT auto-created (verified against Google's docs) —
# provisioning it needs google_project_service_identity, which only exists in
# the hashicorp/google-beta provider. Deliberately not taking on a beta-provider
# dependency in an otherwise all-GA module for this; Google-default encryption
# is still real, FIPS 140-2 validated encryption at rest, just without
# customer key control.

resource "google_secret_manager_secret" "hub_vault_ca" {
  secret_id = "mountos-hub-vault-ca"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "appserv_vault_secret_id" {
  secret_id = "mountos-appserv-vault-secret-id"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "appserv_vault_secret_id" {
  count       = var.vault_secret_id != "" ? 1 : 0
  secret      = google_secret_manager_secret.appserv_vault_secret_id.id
  secret_data = var.vault_secret_id
}

resource "google_secret_manager_secret" "region_vault_ca" {
  secret_id = "mountos-region-vault-ca"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "region_vault_secret_id" {
  secret_id = "mountos-region-vault-secret-id"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "region_vault_secret_id" {
  count       = var.region_vault_secret_id != "" ? 1 : 0
  secret      = google_secret_manager_secret.region_vault_secret_id.id
  secret_data = var.region_vault_secret_id
}
