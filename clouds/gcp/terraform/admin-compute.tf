# mountos-admin-client, optional (var.admin_client_enabled). One direct-IP
# instance with its own static external address and its own domain
# (admin_domain, not hub_domain, so it has a separate WebAuthn origin). Caddy
# gets a real Let's Encrypt certificate and proxies to the Node gateway on
# 127.0.0.1:3001 over plain HTTP. The source is public
# (github.com/mountos-io/mountos-admin-client). The instance clones it and
# unpacks the committed production build, so no prebuilt artifact is shipped.

# ---------- firewall (hub network, tag-targeted) ----------
resource "google_compute_firewall" "admin_client_https" {
  count         = var.admin_client_enabled ? 1 : 0
  name          = "${local.name_root}-admin-client-https"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  target_tags   = ["mountos-admin-client"]
  source_ranges = [var.client_cidr]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

# Let's Encrypt validates from many addresses, so this stays open to the
# internet. Caddy answers only the ACME challenge and redirects the rest to 443.
resource "google_compute_firewall" "admin_client_http_acme" {
  count         = var.admin_client_enabled ? 1 : 0
  name          = "${local.name_root}-admin-client-http-acme"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  target_tags   = ["mountos-admin-client"]
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# ---------- IAM: read only the admin-client secret ----------
# account_id has a 6-30 char total limit. "-admin-client" would overflow it for
# a long resource_prefix, so the shorter "-admin" suffix is used.
resource "google_service_account" "admin_client" {
  count        = var.admin_client_enabled ? 1 : 0
  account_id   = "${local.name_root}-admin"
  display_name = "mountOS admin client"
}

# The seed script creates and fills mountos__admin-client, so no container
# exists at plan time. A project binding conditioned on the exact secret name
# grants access to that one secret and its versions, and nothing else.
resource "google_project_iam_member" "admin_client_secret_reader" {
  count   = var.admin_client_enabled && local.hub_gcp ? 1 : 0
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.admin_client[0].email}"

  condition {
    title      = "${local.name_root}-admin-client-secret"
    expression = "resource.name == \"${local.admin_client_secret_resource}\" || resource.name.startsWith(\"${local.admin_client_secret_resource}/\")"
  }
}

# ---------- instance ----------
resource "google_compute_address" "admin_client" {
  count  = var.admin_client_enabled ? 1 : 0
  name   = "${local.name_root}-admin-client"
  region = var.region
}

locals {
  admin_client_secret_name     = "${local.name_root}__admin-client"
  admin_client_secret_resource = "projects/${data.google_project.current.number}/secrets/${local.admin_client_secret_name}"

  admin_client_startup = var.admin_client_enabled ? templatefile("${path.module}/cloud-init.admin.sh.tftpl", {
    project_id   = var.project_id
    secret_name  = local.admin_client_secret_name
    admin_domain = var.admin_domain
    hub_domain   = var.hub_domain
  }) : ""
}

# The startup script runs once per instance (it guards itself), and a GCP
# instance does not reboot when its metadata changes. The digest forces a
# replacement so a changed script reaches the instance. The static address
# survives the replacement.
resource "terraform_data" "admin_client_boot" {
  count = var.admin_client_enabled ? 1 : 0
  input = sha256(local.admin_client_startup)
}

resource "google_compute_instance" "admin_client" {
  count        = var.admin_client_enabled ? 1 : 0
  name         = "${local.name_root}-admin-client"
  machine_type = var.admin_client_machine_type
  zone         = local.zones[0]
  tags         = ["mountos-admin-client"]

  boot_disk {
    initialize_params {
      image = local.machine_image
      size  = 30
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.public.id
    access_config {
      nat_ip = google_compute_address.admin_client[0].address
    }
  }

  service_account {
    email = google_service_account.admin_client[0].email
    # cloud-platform: see compute.tf's appserv service_account comment.
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    startup-script           = local.admin_client_startup
    block-project-ssh-keys   = "true"
    enable-oslogin           = "TRUE"
    disable-legacy-endpoints = "true"
  }

  labels = {
    mountos_component = "admin-client"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.admin_client_boot[0]]

    precondition {
      condition     = local.hub_gcp
      error_message = "admin_client_enabled currently only supports vault_provider = gcp (Secret Manager). The hashicorp path is not wired for the admin-client secret yet."
    }
  }

  # IAM bindings are eventually consistent. Submit the grant before the
  # instance boots so the first secret read does not race a cold 403.
  depends_on = [google_project_iam_member.admin_client_secret_reader]
}
