# Self-hosted region Vault node (single raft peer). Provisioned only when
# region_vault_hosting = self-hosted. All region-scoped services read their
# own config from this Vault at startup (VAULT_HASHICORP_ADDRESS is a runtime
# env var, not just a boot-time fetch) — dataserv, blockserv, and the
# hdfsserv/s3gatewayserv gateway tag all need real network access, not just
# dataserv (a bug the AWS module shipped once and had to fix later — baked in
# correctly here from the start).

resource "google_service_account" "region_vault" {
  count        = local.region_self_vault ? 1 : 0
  account_id   = "mountos-region-vault"
  display_name = "mountOS region vault"
}

resource "google_secret_manager_secret_iam_member" "region_vault_ca_writer" {
  count     = local.region_self_vault ? 1 : 0
  secret_id = google_secret_manager_secret.region_vault_ca.id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${google_service_account.region_vault[0].email}"
}

resource "google_compute_firewall" "region_vault_api_from_dataserv" {
  count       = local.region_self_vault ? 1 : 0
  name        = "mountos-region-vault-api-from-dataserv"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-region-vault"]
  source_tags = ["mountos-dataserv"]
  allow {
    protocol = "tcp"
    ports    = ["8200"]
  }
}

resource "google_compute_firewall" "region_vault_api_from_blockserv" {
  count       = local.region_self_vault ? 1 : 0
  name        = "mountos-region-vault-api-from-blockserv"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-region-vault"]
  source_tags = ["mountos-blockserv"]
  allow {
    protocol = "tcp"
    ports    = ["8200"]
  }
}

resource "google_compute_firewall" "region_vault_api_from_gateway" {
  count       = local.region_self_vault ? 1 : 0
  name        = "mountos-region-vault-api-from-gateway"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-region-vault"]
  source_tags = ["mountos-gateway"]
  allow {
    protocol = "tcp"
    ports    = ["8200"]
  }
}

resource "google_compute_firewall" "region_vault_raft_self" {
  count       = local.region_self_vault ? 1 : 0
  name        = "mountos-region-vault-raft-self"
  network     = local.region_network
  direction   = "INGRESS"
  target_tags = ["mountos-region-vault"]
  source_tags = ["mountos-region-vault"]
  allow {
    protocol = "tcp"
    ports    = ["8201"]
  }
}

resource "google_compute_instance" "region_vault" {
  count        = local.region_self_vault ? 1 : 0
  name         = "mountos-region-vault"
  machine_type = var.region_vault_machine_type
  zone         = local.zones[0]
  tags         = ["mountos-region-vault"]

  boot_disk {
    initialize_params {
      image = local.machine_image
    }
  }

  network_interface {
    subnetwork = local.region_private_subnet.id
  }

  service_account {
    email = google_service_account.region_vault[0].email
    # cloud-platform: see compute.tf's appserv service_account comment.
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    block-project-ssh-keys   = "true"
    enable-oslogin           = "TRUE"
    disable-legacy-endpoints = "true"
  }

  metadata_startup_script = templatefile("${path.module}/region-vault-init.sh.tftpl", {
    project_id = var.project_id
    region     = var.region
    ca_secret  = google_secret_manager_secret.region_vault_ca.secret_id
  })

  depends_on = [
    google_kms_crypto_key_iam_member.region_vault,
    google_secret_manager_secret_iam_member.region_vault_ca_writer,
  ]
}
