# Secret Manager resources for both secret-store providers.
#
# replication.auto (Google-default encryption), not customer_managed_encryption:
# CMEK here would need the Secret Manager service agent to hold decrypt on the
# CMK, and that agent is NOT auto-created (verified against Google's docs) —
# provisioning it needs google_project_service_identity, which only exists in
# the hashicorp/google-beta provider. Deliberately not taking on a beta-provider
# dependency in an otherwise all-GA module for this; Google-default encryption
# is still real, FIPS 140-2 validated encryption at rest, just without
# customer key control.

locals {
  # Fixed names, referenced by both the resources below and the cloud-init
  # templates (literal strings there, so gcp-mode plans never touch the
  # hashicorp-gated resources).
  hub_vault_ca_secret_name    = "mountos-hub-vault-ca"
  appserv_secret_id_name      = "mountos-appserv-vault-secret-id"
  region_vault_ca_secret_name = "mountos-region-vault-ca"
  region_vault_secret_id_name = "mountos-region-vault-secret-id"
}

# ---------- byo Vault delivery (vault_provider = hashicorp only) ----------
# A byo Vault with a PRIVATE CA gets its operator-supplied CA published by
# Terraform so instances can trust it. Public-CA byo Vaults leave the pem
# empty (instances then use system CAs and skip the fetch). The secret_id
# containers exist for the whole hashicorp lifetime — the unit's ExecStartPre
# polls them, so a first apply before the seed runs is tolerated (no version
# yet -> systemd retries).

resource "google_secret_manager_secret" "hub_vault_ca" {
  count     = local.hub_hashicorp && var.vault_ca_pem != "" ? 1 : 0
  secret_id = local.hub_vault_ca_secret_name
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "hub_vault_ca_byo" {
  count       = local.hub_hashicorp && var.vault_ca_pem != "" ? 1 : 0
  secret      = google_secret_manager_secret.hub_vault_ca[0].id
  secret_data = var.vault_ca_pem
}

resource "google_secret_manager_secret" "appserv_vault_secret_id" {
  count     = local.hub_hashicorp ? 1 : 0
  secret_id = local.appserv_secret_id_name
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "appserv_vault_secret_id" {
  count       = local.hub_hashicorp && var.vault_secret_id != "" ? 1 : 0
  secret      = google_secret_manager_secret.appserv_vault_secret_id[0].id
  secret_data = var.vault_secret_id
}

resource "google_secret_manager_secret" "region_vault_ca" {
  count     = local.region_hashicorp && var.region_vault_ca_pem != "" ? 1 : 0
  secret_id = local.region_vault_ca_secret_name
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "region_vault_ca_byo" {
  count       = local.region_hashicorp && var.region_vault_ca_pem != "" ? 1 : 0
  secret      = google_secret_manager_secret.region_vault_ca[0].id
  secret_data = var.region_vault_ca_pem
}

resource "google_secret_manager_secret" "region_vault_secret_id" {
  count     = local.region_hashicorp ? 1 : 0
  secret_id = local.region_vault_secret_id_name
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "region_vault_secret_id" {
  count       = local.region_hashicorp && var.region_vault_secret_id != "" ? 1 : 0
  secret      = google_secret_manager_secret.region_vault_secret_id[0].id
  secret_data = var.region_vault_secret_id
}

# ---------- cloud-native secret store (vault_provider = gcp) ----------
# The servers map logical paths to Secret Manager ids as mountos__<path> with
# "/" -> "__" (mountos-servers/internal/secrets/gcp.go). Terraform pre-creates
# the STATIC containers (empty — the seed scripts and services add versions)
# so read access can be granted per secret, which is what enforces the two
# hard isolation rules: appserv can NEVER read mountos__api-master, and region
# services can NEVER read mountos__appserv.
#
# The blockserv worker container is created whenever the region uses the gcp
# provider, independent of the fleet enable toggle: `make region-bootstrap`
# seeds it unconditionally, and a later enable must not fight the seed over
# container ownership.
#
# The DYNAMIC per-volume credential secrets (mountos__s3creds__*,
# mountos__volcreds__*) are created at runtime by dataserv/gcserv and are
# covered by prefix-conditioned project IAM instead (see region-iam.tf).
#
# prevent_destroy on every container: they hold LIVE payloads once seeded
# (api-master is write-once) — a provider flip must fail the plan, not
# destroy them.

resource "google_secret_manager_secret" "appserv_config" {
  count     = local.hub_gcp ? 1 : 0
  secret_id = "mountos__appserv"
  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret" "service_verifiers" {
  count     = local.hub_gcp || local.region_gcp ? 1 : 0
  secret_id = "mountos__service-verifiers"
  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret" "dataserv_config" {
  count     = local.region_gcp ? 1 : 0
  secret_id = "mountos__dataserv"
  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret" "gcserv_config" {
  count     = local.region_gcp ? 1 : 0
  secret_id = "mountos__gcserv"
  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret" "api_master" {
  count     = local.region_gcp ? 1 : 0
  secret_id = "mountos__api-master"
  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret" "blockserv_config" {
  count     = local.region_gcp ? 1 : 0
  secret_id = "mountos__blockserv"
  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }
}
