resource "google_compute_instance_template" "hdfsserv" {
  count        = var.hdfs_enable ? 1 : 0
  name_prefix  = "mountos-hdfsserv-"
  machine_type = var.hdfs_machine_type
  tags         = ["mountos-gateway"]

  disk {
    source_image = local.machine_image
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = local.region_public_subnet.id
    access_config {} # ephemeral external IP: hdfsserv advertises a public IPv4
  }

  service_account {
    email = google_service_account.hdfsserv[0].email
    # cloud-platform: see compute.tf's appserv service_account comment.
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    startup-script = templatefile("${path.module}/hdfs-cloud-init.hdfsserv.sh.tftpl", {
      vault_addr              = local.region_vault_endpoint
      vault_role_id           = var.region_vault_role_id
      project_id              = var.project_id
      region_vault_ca_secret  = google_secret_manager_secret.region_vault_ca.secret_id
      region_secret_id_secret = google_secret_manager_secret.region_vault_secret_id.secret_id
      region_cluster_id       = var.region_cluster_id
      srpc_addr               = "${google_compute_forwarding_rule.appserv_srpc.ip_address}:9443"
      mos_version             = var.mos_version
      mos_installer_sha256    = var.mos_installer_sha256
    })
    block-project-ssh-keys   = "true"
    enable-oslogin           = "TRUE"
    disable-legacy-endpoints = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_health_check" "hdfsserv" {
  count = var.hdfs_enable ? 1 : 0
  name  = "mountos-hdfsserv"
  tcp_health_check {
    port = 9870
  }
  healthy_threshold   = 2
  unhealthy_threshold = 3
  check_interval_sec  = 10
  timeout_sec         = 5
}

resource "google_compute_region_instance_group_manager" "hdfsserv" {
  count              = var.hdfs_enable ? 1 : 0
  name               = "mountos-hdfsserv"
  region             = var.region
  base_instance_name = "mountos-hdfsserv"
  target_size        = var.hdfs_count

  version {
    instance_template = google_compute_instance_template.hdfsserv[0].id
  }

  distribution_policy_zones = local.zones

  auto_healing_policies {
    health_check      = google_compute_health_check.hdfsserv[0].id
    initial_delay_sec = 300
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
  }

  depends_on = [
    google_secret_manager_secret_version.region_vault_secret_id,
    google_secret_manager_secret_iam_member.hdfsserv_secret_id_reader,
    google_secret_manager_secret_iam_member.hdfsserv_vault_ca_reader,
  ]
}
