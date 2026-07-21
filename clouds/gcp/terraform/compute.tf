resource "google_compute_instance_template" "appserv" {
  name_prefix  = "${local.name_root}-appserv-"
  machine_type = var.appserv_machine_type
  tags         = ["mountos-appserv"]

  disk {
    source_image = local.machine_image
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.private.id
    # No access_config: no external IP. appserv is reached via the LB, never directly.
  }

  service_account {
    email = google_service_account.appserv.email
    # cloud-platform is Google's documented best practice here, not a broad-
    # scope oversight: Secret Manager/Cloud KMS have no narrower legacy OAuth
    # scope alias, so authorization is enforced entirely via the (already
    # per-service, verified-narrow) IAM bindings, not by the OAuth scope.
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    startup-script = templatefile("${path.module}/cloud-init.appserv.sh.tftpl", {
      vault_provider           = var.vault_provider
      vault_addr               = var.vault_addr
      vault_role_id            = var.vault_role_id
      vault_ca_source          = local.hub_vault_ca_source
      project_id               = var.project_id
      hub_vault_ca_secret      = local.hub_vault_ca_secret_name
      appserv_secret_id_secret = local.appserv_secret_id_name
      mos_version              = var.mos_version
      mos_installer_sha256     = var.mos_installer_sha256
    })
    block-project-ssh-keys   = "true"
    enable-oslogin           = "TRUE"
    disable-legacy-endpoints = "true"
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = !local.hub_hashicorp || var.vault_addr != ""
      error_message = "vault_provider = hashicorp requires vault_addr (the https address of your byo Vault; this package never launches one)."
    }
    precondition {
      condition     = local.hub_hashicorp || (var.vault_addr == "" && var.vault_ca_pem == "" && var.vault_role_id == "")
      error_message = "vault_addr/vault_ca_pem/vault_role_id are only for vault_provider = hashicorp — the gcp provider uses Secret Manager with instance service accounts."
    }
  }
}

resource "google_compute_health_check" "appserv" {
  name = "${local.name_root}-appserv"
  https_health_check {
    port         = 8443
    request_path = "/api/v1/me"
  }
  healthy_threshold   = 2
  unhealthy_threshold = 3
  check_interval_sec  = 10
  timeout_sec         = 5
}

resource "google_compute_region_instance_group_manager" "appserv" {
  name               = "${local.name_root}-appserv"
  region             = var.region
  base_instance_name = "${local.name_root}-appserv"
  target_size        = var.appserv_count

  version {
    instance_template = google_compute_instance_template.appserv.id
  }

  distribution_policy_zones = local.zones

  named_port {
    name = "https"
    port = 8443
  }

  named_port {
    name = "srpc"
    port = 9443
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.appserv.id
    initial_delay_sec = 300
  }

  # `make upgrade` (bump mos_version -> apply) rolls the fleet, not just new instances.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
  }

  # IAM member bindings are eventually consistent; submit the grants before the
  # fleet boots so ExecStartPre / SDK reads aren't racing a cold 403.
  depends_on = [
    google_secret_manager_secret_version.appserv_vault_secret_id,
    google_secret_manager_secret_iam_member.appserv_secret_id_reader,
    google_secret_manager_secret_iam_member.appserv_vault_ca_reader,
    google_secret_manager_secret_iam_member.appserv_own_reader,
    google_secret_manager_secret_iam_member.appserv_verifiers_reader,
    google_project_iam_member.appserv_secret_viewer,
  ]
}
