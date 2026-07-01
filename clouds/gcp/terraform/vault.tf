# Self-hosted Vault node (single raft peer). Provisioned only when vault_hosting = self-hosted.
# HA: scale to 3 raft peers later (see vault-init.sh.tftpl note).

resource "google_compute_firewall" "vault_api_from_appserv" {
  count       = local.self_vault ? 1 : 0
  name        = "mountos-vault-api-from-appserv"
  network     = google_compute_network.main.id
  direction   = "INGRESS"
  target_tags = ["mountos-vault"]
  source_tags = ["mountos-appserv"]
  allow {
    protocol = "tcp"
    ports    = ["8200"]
  }
}

resource "google_compute_firewall" "vault_raft_self" {
  count       = local.self_vault ? 1 : 0
  name        = "mountos-vault-raft-self"
  network     = google_compute_network.main.id
  direction   = "INGRESS"
  target_tags = ["mountos-vault"]
  source_tags = ["mountos-vault"]
  allow {
    protocol = "tcp"
    ports    = ["8201"]
  }
}

resource "google_compute_instance" "vault" {
  count        = local.self_vault ? 1 : 0
  name         = "mountos-vault"
  machine_type = var.vault_machine_type
  zone         = local.zones[0]
  tags         = ["mountos-vault"]

  boot_disk {
    initialize_params {
      image = local.machine_image
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    # No access_config: no external IP. Egress via Cloud NAT (network.tf).
  }

  service_account {
    email = google_service_account.vault[0].email
    # cloud-platform: see compute.tf's appserv service_account comment.
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-guest-attributes  = "TRUE"
    block-project-ssh-keys   = "true"
    enable-oslogin           = "TRUE"
    disable-legacy-endpoints = "true"
  }

  metadata_startup_script = templatefile("${path.module}/vault-init.sh.tftpl", {
    kms_key_id = google_kms_crypto_key.hub.id
    project_id = var.project_id
    ca_secret  = google_secret_manager_secret.hub_vault_ca.secret_id
  })

  # IAM member bindings are eventually consistent; submit both grants before
  # boot so Vault's startup retry loop isn't racing a cold 403.
  depends_on = [
    google_kms_crypto_key_iam_member.hub_vault,
    google_secret_manager_secret_iam_member.vault_ca_writer,
  ]
}
