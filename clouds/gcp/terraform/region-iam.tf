# One service account per region service (dataserv/gcserv co-located,
# blockserv) — blast-radius isolation, matching the AWS module's per-service
# IAM role even where services share a security group/tag.

resource "google_service_account" "dataserv" {
  account_id   = "mountos-dataserv"
  display_name = "mountOS dataserv/gcserv"
}

resource "google_service_account" "blockserv" {
  count        = var.block_enable ? 1 : 0
  account_id   = "mountos-blockserv"
  display_name = "mountOS blockserv"
}

# ---------- byo Vault (region_vault_provider = hashicorp) ----------
# All region services read the same region Vault CA + AppRole secret_id (same
# region AppRole) that Terraform publishes to Secret Manager (secrets.tf).

locals {
  region_hashicorp_readers = local.region_hashicorp ? merge(
    { dataserv = "serviceAccount:${google_service_account.dataserv.email}" },
    var.block_enable ? { blockserv = "serviceAccount:${google_service_account.blockserv[0].email}" } : {},
  ) : {}
}

resource "google_secret_manager_secret_iam_member" "region_secret_id_reader" {
  for_each  = local.region_hashicorp_readers
  secret_id = google_secret_manager_secret.region_vault_secret_id[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}

resource "google_secret_manager_secret_iam_member" "region_vault_ca_reader" {
  for_each  = var.region_vault_ca_pem != "" ? local.region_hashicorp_readers : {}
  secret_id = google_secret_manager_secret.region_vault_ca[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}

# ---------- cloud-native secret store (region_vault_provider = gcp) ----------
# Permission matrix (per-secret grants on the containers from secrets.tf):
#   dataserv + co-located gcserv: read own configs, verifiers, api-master;
#     write api-master (gcserv rotation) and full CRUD on the runtime-created
#     per-volume credential secrets (mountos__s3creds__*/mountos__volcreds__*).
#   blockserv: read-only, own config plus verifiers and volume credentials.
# Hard rules preserved (see iam.tf): appserv never reads mountos__api-master,
# region services never read mountos__appserv.
#
# The dynamic per-volume secrets don't exist at plan time, so they can't carry
# per-secret IAM. They get project-level bindings CONDITIONED on the secret
# name prefix instead (Secret Manager supports resource.name in IAM
# conditions; resource names carry the project NUMBER). Two custom roles fill
# gaps the built-in set can't cover narrowly:
#   - secretmanager.secrets.create is authorized on the PROJECT parent, so a
#     name-prefix condition can never match it — it needs a small
#     unconditioned grant. A create-only custom role is the narrowest carrier;
#     roles/secretmanager.admin would also carry setIamPolicy on every secret,
#     an indirect path around the isolation rules, so it is NOT used. The
#     create grant is also required for updates: the servers idempotently
#     CreateSecret before every version write (AlreadyExists is swallowed),
#     including the api-master rotation path.
#   - secretmanager.secrets.delete only ships in roles/secretmanager.admin, so
#     the prefix-conditioned writer role is custom too.
# Trade-off accepted: dataserv can create arbitrarily-named (empty) secrets in
# the project, but can only read/write/delete payloads under the conditioned
# prefixes and its per-secret grants.

locals {
  dynamic_secret_condition = join(" || ", [
    "resource.name.startsWith(\"projects/${data.google_project.current.number}/secrets/mountos__s3creds__\")",
    "resource.name.startsWith(\"projects/${data.google_project.current.number}/secrets/mountos__volcreds__\")",
  ])
}

resource "google_project_iam_custom_role" "secret_creator" {
  count       = local.region_gcp ? 1 : 0
  role_id     = "mountosSecretCreator"
  title       = "mountOS secret creator"
  description = "Create Secret Manager secret containers only (no payload access)."
  permissions = ["secretmanager.secrets.create"]
}

resource "google_project_iam_custom_role" "dynamic_secret_writer" {
  count       = local.region_gcp ? 1 : 0
  role_id     = "mountosDynamicSecretWriter"
  title       = "mountOS dynamic secret writer"
  description = "Read/write/delete secret payloads; bound only with a mountos__s3creds__/mountos__volcreds__ name condition."
  permissions = [
    "secretmanager.secrets.get",
    "secretmanager.secrets.delete",
    "secretmanager.versions.access",
    "secretmanager.versions.add",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
  ]
}

# dataserv + co-located gcserv: reads.
resource "google_secret_manager_secret_iam_member" "dataserv_own_reader" {
  count     = local.region_gcp ? 1 : 0
  secret_id = google_secret_manager_secret.dataserv_config[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.dataserv.email}"
}

resource "google_secret_manager_secret_iam_member" "dataserv_gcserv_reader" {
  count     = local.region_gcp ? 1 : 0
  secret_id = google_secret_manager_secret.gcserv_config[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.dataserv.email}"
}

resource "google_secret_manager_secret_iam_member" "dataserv_verifiers_reader" {
  count     = local.region_gcp ? 1 : 0
  secret_id = google_secret_manager_secret.service_verifiers[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.dataserv.email}"
}

resource "google_secret_manager_secret_iam_member" "dataserv_api_master_reader" {
  count     = local.region_gcp ? 1 : 0
  secret_id = google_secret_manager_secret.api_master[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.dataserv.email}"
}

# gcserv rotates api-master: add versions to the existing container.
resource "google_secret_manager_secret_iam_member" "dataserv_api_master_writer" {
  count     = local.region_gcp ? 1 : 0
  secret_id = google_secret_manager_secret.api_master[0].id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${google_service_account.dataserv.email}"
}

resource "google_project_iam_member" "dataserv_secret_creator" {
  count   = local.region_gcp ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.secret_creator[0].id
  member  = "serviceAccount:${google_service_account.dataserv.email}"
}

resource "google_project_iam_member" "dataserv_dynamic_writer" {
  count   = local.region_gcp ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.dynamic_secret_writer[0].id
  member  = "serviceAccount:${google_service_account.dataserv.email}"

  condition {
    title      = "mountos-dynamic-creds"
    expression = local.dynamic_secret_condition
  }
}

# SecretStore.Ping + version-metadata listing; see iam.tf's viewer note
# (metadata-only, never payloads).
resource "google_project_iam_member" "dataserv_secret_viewer" {
  count   = local.region_gcp ? 1 : 0
  project = var.project_id
  role    = "roles/secretmanager.viewer"
  member  = "serviceAccount:${google_service_account.dataserv.email}"
}

# blockserv: read-only, own config plus verifiers and volume credentials.
locals {
  region_gcp_workers = local.region_gcp ? merge(
    var.block_enable ? { blockserv = {
      member     = "serviceAccount:${google_service_account.blockserv[0].email}",
      own_secret = google_secret_manager_secret.blockserv_config[0].id,
    } } : {},
  ) : {}
}

resource "google_secret_manager_secret_iam_member" "worker_own_reader" {
  for_each  = local.region_gcp_workers
  secret_id = each.value.own_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member
}

resource "google_secret_manager_secret_iam_member" "worker_verifiers_reader" {
  for_each  = local.region_gcp_workers
  secret_id = google_secret_manager_secret.service_verifiers[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member
}

resource "google_project_iam_member" "worker_dynamic_reader" {
  for_each = local.region_gcp_workers
  project  = var.project_id
  role     = "roles/secretmanager.secretAccessor"
  member   = each.value.member

  condition {
    title      = "mountos-dynamic-creds"
    expression = local.dynamic_secret_condition
  }
}

resource "google_project_iam_member" "worker_secret_viewer" {
  for_each = local.region_gcp_workers
  project  = var.project_id
  role     = "roles/secretmanager.viewer"
  member   = each.value.member
}
