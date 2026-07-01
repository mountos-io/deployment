# dataserv fleet (+ co-located gcserv). Registers with the hub over SRPC at the
# hub internal LB; reaches the region Vault over the network (no KMS on dataserv).
# PUBLIC subnet: dataserv advertises a public IPv4 (see region-cloud-init).

resource "google_compute_instance_template" "dataserv" {
  name_prefix  = "mountos-dataserv-"
  machine_type = var.dataserv_machine_type
  tags         = var.gcserv_colocated ? ["mountos-dataserv", "mountos-gcserv"] : ["mountos-dataserv"]

  disk {
    source_image = local.machine_image
    auto_delete  = true
    boot         = true
  }

  # Raft data disk. auto_delete: ephemeral per instance (delete_on_termination
  # equivalent) — a replaced node rejoins quorum and re-syncs from peers; raft
  # state is NOT migrated across replacements.
  disk {
    auto_delete  = true
    boot         = false
    disk_type    = "pd-ssd"
    disk_size_gb = var.raft_disk_gb
    device_name  = "raft"
  }

  network_interface {
    subnetwork = local.region_public_subnet.id
    access_config {} # external IP: dataserv advertises a public IPv4
  }

  service_account {
    email = google_service_account.dataserv.email
    # cloud-platform: see compute.tf's appserv service_account comment.
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    startup-script = templatefile("${path.module}/region-cloud-init.dataserv.sh.tftpl", {
      vault_addr              = local.region_vault_endpoint
      vault_role_id           = var.region_vault_role_id
      project_id              = var.project_id
      region_vault_ca_secret  = google_secret_manager_secret.region_vault_ca.secret_id
      region_secret_id_secret = google_secret_manager_secret.region_vault_secret_id.secret_id
      region_cluster_id       = var.region_cluster_id
      srpc_addr               = "${google_compute_forwarding_rule.appserv_srpc.ip_address}:9443"
      arena_size              = var.arena_size
      mos_version             = var.mos_version
      mos_installer_sha256    = var.mos_installer_sha256
      gcserv_colocated        = var.gcserv_colocated
    })
    block-project-ssh-keys   = "true"
    enable-oslogin           = "TRUE"
    disable-legacy-endpoints = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# health_check_type: dataserv is not behind the hub LBs, so a simple
# auto-healing health check keyed on the client port is enough. Raft quorum
# forms via the 6465 peer firewall rule; instances discover peers via hub
# registration.
resource "google_compute_health_check" "dataserv" {
  name = "mountos-dataserv"
  tcp_health_check {
    port = 6464
  }
  healthy_threshold   = 2
  unhealthy_threshold = 3
  check_interval_sec  = 10
  timeout_sec         = 5
}

resource "google_compute_region_instance_group_manager" "dataserv" {
  name               = "mountos-dataserv"
  region             = var.region
  base_instance_name = "mountos-dataserv"
  target_size        = var.dataserv_count

  version {
    instance_template = google_compute_instance_template.dataserv.id
  }

  distribution_policy_zones = local.zones

  auto_healing_policies {
    health_check      = google_compute_health_check.dataserv.id
    initial_delay_sec = 300
  }

  # `make upgrade` (bump mos_version -> apply) rolls the fleet. min_healthy
  # via max_unavailable_fixed=0 keeps quorum during refresh (mirrors AWS's 67%).
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
  }

  depends_on = [
    google_secret_manager_secret_version.region_vault_secret_id,
    google_secret_manager_secret_iam_member.dataserv_secret_id_reader,
    google_secret_manager_secret_iam_member.dataserv_vault_ca_reader,
  ]
}
