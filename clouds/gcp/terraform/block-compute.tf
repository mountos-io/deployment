# blockserv data-plane members. Each member is a distinct google_compute_instance
# with its own BLOCK_VOLUME_ID and its own cache disk, spread across zones.
# Each gets a stable static external IP (not ephemeral): unlike the MIG-based
# fleets, blockserv members are individually addressed by a persistent
# BLOCK_VOLUME_ID and aren't expected to churn via rolling replacement, so a
# stable address avoids unnecessary re-discovery.

resource "google_compute_address" "blockserv" {
  for_each = local.block_members_map
  name     = "mountos-blockserv-${each.key}"
  region   = var.region
}

resource "google_compute_disk" "blockserv_cache" {
  for_each = local.block_members_map
  name     = "mountos-blockserv-cache-${each.key}"
  zone     = local.zones[each.value.zone_index % length(local.zones)]
  type     = var.block_cache_type
  size     = var.block_cache_gb
}

resource "google_compute_instance" "blockserv" {
  for_each     = local.block_members_map
  name         = "mountos-blockserv-${each.key}"
  machine_type = var.block_machine_type
  zone         = local.zones[each.value.zone_index % length(local.zones)]
  tags         = ["mountos-blockserv"]

  boot_disk {
    initialize_params {
      image = local.machine_image
      size  = 30
    }
  }

  attached_disk {
    source      = google_compute_disk.blockserv_cache[each.key].id
    device_name = "blockcache"
  }

  network_interface {
    subnetwork = local.region_public_subnet.id
    access_config {
      nat_ip = google_compute_address.blockserv[each.key].address
    }
  }

  service_account {
    email = google_service_account.blockserv[0].email
    # cloud-platform: see compute.tf's appserv service_account comment.
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    startup-script = templatefile("${path.module}/block-cloud-init.blockserv.sh.tftpl", {
      vault_addr              = local.region_vault_endpoint
      vault_role_id           = var.region_vault_role_id
      project_id              = var.project_id
      region_vault_ca_secret  = google_secret_manager_secret.region_vault_ca.secret_id
      region_secret_id_secret = google_secret_manager_secret.region_vault_secret_id.secret_id
      region_cluster_id       = var.region_cluster_id
      srpc_addr               = "${google_compute_forwarding_rule.appserv_srpc.ip_address}:9443"
      advertise_addr          = google_compute_address.blockserv[each.key].address
      block_volume_id         = each.value.block_volume_id
      delete_mode             = var.block_delete_mode
      mos_version             = var.mos_version
      mos_installer_sha256    = var.mos_installer_sha256
    })
    block-project-ssh-keys   = "true"
    enable-oslogin           = "TRUE"
    disable-legacy-endpoints = "true"
  }

  depends_on = [
    google_secret_manager_secret_version.region_vault_secret_id,
    google_secret_manager_secret_iam_member.blockserv_secret_id_reader,
    google_secret_manager_secret_iam_member.blockserv_vault_ca_reader,
  ]
}
