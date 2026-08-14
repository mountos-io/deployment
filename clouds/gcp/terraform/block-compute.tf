# blockserv data-plane members. Each member is a distinct google_compute_instance
# with its own BLOCK_VOLUME_ID and its own cache disk, spread across zones.
# Each gets a stable static external IP (not ephemeral): unlike the MIG-based
# fleets, blockserv members are individually addressed by a persistent
# BLOCK_VOLUME_ID and aren't expected to churn via rolling replacement, so a
# stable address avoids unnecessary re-discovery.

resource "google_compute_address" "blockserv" {
  for_each = local.block_members_map
  name     = "${local.name_root}-blockserv-${each.key}"
  region   = var.region
}

resource "google_compute_disk" "blockserv_cache" {
  for_each = local.block_members_map
  name     = "${local.name_root}-blockserv-cache-${each.key}"
  zone     = local.zones[each.value.zone_index % length(local.zones)]
  type     = var.block_cache_type
  size     = var.block_cache_gb
}

# Rendered once here so its digest can drive replacement below. GCP metadata
# updates in place and nothing reboots the instance, so without an explicit
# trigger a mos_version bump would change the stored script and leave every
# blockserv member running the old binary indefinitely. The MIG-backed fleets
# roll on their own; a bare google_compute_instance does not.
#
# That trigger replaces every changed member in the SAME apply, which takes the
# active-active mesh down together. Use `make block-roll` rather than a bare
# apply once the mesh is serving: it walks the members one at a time.
locals {
  blockserv_startup = {
    for k, v in local.block_members_map : k => templatefile("${path.module}/block-cloud-init.blockserv.sh.tftpl", {
      vault_provider          = var.region_vault_provider
      vault_addr              = var.region_vault_addr
      vault_role_id           = var.region_vault_role_id
      vault_ca_source         = local.region_vault_ca_source
      project_id              = var.project_id
      region_vault_ca_secret  = local.region_vault_ca_secret_name
      region_secret_id_secret = local.region_vault_secret_id_name
      region_cluster_id       = var.region_cluster_id
      srpc_addr               = "${google_compute_forwarding_rule.appserv_srpc.ip_address}:9443"
      advertise_addr          = google_compute_address.blockserv[k].address
      block_volume_id         = v.block_volume_id
      delete_mode             = var.block_delete_mode
      mos_version             = var.mos_version
      mos_installer_sha256    = var.mos_installer_sha256
      resource_prefix         = var.resource_prefix
    })
  }
}

# Digest-only resource: its sole purpose is to make the instance replace when
# the rendered startup script changes.
resource "terraform_data" "blockserv_boot" {
  for_each = local.block_members_map
  input    = sha256(local.blockserv_startup[each.key])
}

resource "google_compute_instance" "blockserv" {
  for_each     = local.block_members_map
  name         = "${local.name_root}-blockserv-${each.key}"
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
    startup-script           = local.blockserv_startup[each.key]
    block-project-ssh-keys   = "true"
    enable-oslogin           = "TRUE"
    disable-legacy-endpoints = "true"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.blockserv_boot[each.key]]
  }

  depends_on = [
    google_secret_manager_secret_version.region_vault_secret_id,
    google_secret_manager_secret_iam_member.region_secret_id_reader,
    google_secret_manager_secret_iam_member.region_vault_ca_reader,
    google_secret_manager_secret_iam_member.worker_own_reader,
    google_secret_manager_secret_iam_member.worker_verifiers_reader,
    google_project_iam_member.worker_dynamic_reader,
    google_project_iam_member.worker_secret_viewer,
  ]
}
