# Per-scope KMS keys. Each backs its scope's Vault auto-unseal (gcpckms seal)
# and enforces isolation: a region node's service account can use only the
# region key, never the hub key.

resource "google_kms_key_ring" "mountos" {
  name     = "mountos"
  location = var.region
}

resource "google_kms_crypto_key" "hub" {
  name            = "mountos-hub"
  key_ring        = google_kms_key_ring.mountos.id
  rotation_period = "7776000s" # 90 days
  purpose         = "ENCRYPT_DECRYPT"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "hub_vault" {
  count         = local.self_vault ? 1 : 0
  crypto_key_id = google_kms_crypto_key.hub.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.vault[0].email}"
}

resource "google_kms_crypto_key" "region" {
  name            = "mountos-region"
  key_ring        = google_kms_key_ring.mountos.id
  rotation_period = "7776000s"
  purpose         = "ENCRYPT_DECRYPT"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "region_vault" {
  count         = local.region_self_vault ? 1 : 0
  crypto_key_id = google_kms_crypto_key.region.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.region_vault[0].email}"
}

output "kms_key_ids" {
  value = {
    hub    = google_kms_crypto_key.hub.id
    region = google_kms_crypto_key.region.id
  }
}
