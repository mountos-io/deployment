# One managed identity per region service (dataserv/gcserv co-located,
# blockserv, hdfsserv+s3gatewayserv share the "gateway" tier the same way they
# share an ASG) — blast-radius isolation, matching the AWS module's
# per-service IAM role even where services share a security group/tag.
#
# hashicorp provider: role assignments are scoped to the individual secret
# paths, not the vault (Azure RBAC supports scoping to
# "<vault-id>/secrets/<name>" even before that secret exists - resolved at
# access time, not assignment-creation time). All services read the same
# region Key Vault CA + AppRole secret_id (same region AppRole); the actual
# service secrets live in the byo Vault behind its own AppRole ACLs.
#
# azure provider: the region Key Vault IS the store. dataserv/gcserv own
# dynamic per-volume credential names (mountos--s3creds--*,
# mountos--volcreds--*) plus mountos--api-master rotation, and a service reads
# exactly ONE store (VAULT_AZURE_URL) — Azure RBAC cannot scope to a name
# pattern, so per-secret grants cannot carry the matrix. dataserv gets a
# vault-scoped Secrets Officer and the read-only workers a vault-scoped
# Secrets User instead. That is WIDER than the AWS/GCP matrix, and the full
# honest extent is: workers can read every static region secret, including
# mountos--api-master, dataserv/gcserv's Ed25519 SIGNING keys, and their
# DB_URL (the mountos_data DSN with password) — a compromised gateway node
# therefore escalates to region-DB access on Azure where AWS/GCP would deny
# it. Accepted as a documented Azure RBAC limitation because the region vault
# holds ONLY region-scoped material: the cross-scope rules still hold —
# mountos--appserv lives in the hub vault (region identities have no grants
# there) and both provision-pg raw DB passwords live in the hub vault too
# (rds.tf, region-rds.tf). Tightening option if runtime validation shows the
# workers never read s3creds/volcreds directly: replace their vault-scoped
# Secrets User with per-secret grants on own-config + service-verifiers.
locals {
  region_ca_secret_scope        = "${azurerm_key_vault.region.id}/secrets/mountos-region-vault-ca"
  region_secret_id_secret_scope = "${azurerm_key_vault.region.id}/secrets/mountos-region-vault-secret-id"
  region_azure_store            = var.region_vault_provider == "azure"
}

resource "azurerm_user_assigned_identity" "dataserv" {
  name                = "mountos-dataserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "dataserv_ca_reader" {
  count                = local.region_hashicorp ? 1 : 0
  scope                = local.region_ca_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.dataserv.principal_id
}

resource "azurerm_role_assignment" "dataserv_secret_id_reader" {
  count                = local.region_hashicorp ? 1 : 0
  scope                = local.region_secret_id_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.dataserv.principal_id
}

# azure provider: read own configs/verifiers/api-master + full CRUD on the
# dynamic s3creds/volcreds names and api-master rotation (gcserv).
resource "azurerm_role_assignment" "dataserv_secretstore" {
  count                = local.region_azure_store ? 1 : 0
  scope                = azurerm_key_vault.region.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.dataserv.principal_id
}

resource "azurerm_user_assigned_identity" "blockserv" {
  count               = var.block_enable ? 1 : 0
  name                = "mountos-blockserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "blockserv_ca_reader" {
  count                = var.block_enable && local.region_hashicorp ? 1 : 0
  scope                = local.region_ca_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.blockserv[0].principal_id
}

resource "azurerm_role_assignment" "blockserv_secret_id_reader" {
  count                = var.block_enable && local.region_hashicorp ? 1 : 0
  scope                = local.region_secret_id_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.blockserv[0].principal_id
}

resource "azurerm_role_assignment" "blockserv_secretstore" {
  count                = var.block_enable && local.region_azure_store ? 1 : 0
  scope                = azurerm_key_vault.region.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.blockserv[0].principal_id
}

resource "azurerm_user_assigned_identity" "hdfsserv" {
  count               = var.hdfs_enable ? 1 : 0
  name                = "mountos-hdfsserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "hdfsserv_ca_reader" {
  count                = var.hdfs_enable && local.region_hashicorp ? 1 : 0
  scope                = local.region_ca_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.hdfsserv[0].principal_id
}

resource "azurerm_role_assignment" "hdfsserv_secret_id_reader" {
  count                = var.hdfs_enable && local.region_hashicorp ? 1 : 0
  scope                = local.region_secret_id_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.hdfsserv[0].principal_id
}

resource "azurerm_role_assignment" "hdfsserv_secretstore" {
  count                = var.hdfs_enable && local.region_azure_store ? 1 : 0
  scope                = azurerm_key_vault.region.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.hdfsserv[0].principal_id
}

resource "azurerm_user_assigned_identity" "s3gatewayserv" {
  count               = var.s3gateway_enable ? 1 : 0
  name                = "mountos-s3gatewayserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "s3gatewayserv_ca_reader" {
  count                = var.s3gateway_enable && local.region_hashicorp ? 1 : 0
  scope                = local.region_ca_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.s3gatewayserv[0].principal_id
}

resource "azurerm_role_assignment" "s3gatewayserv_secret_id_reader" {
  count                = var.s3gateway_enable && local.region_hashicorp ? 1 : 0
  scope                = local.region_secret_id_secret_scope
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.s3gatewayserv[0].principal_id
}

resource "azurerm_role_assignment" "s3gatewayserv_secretstore" {
  count                = var.s3gateway_enable && local.region_azure_store ? 1 : 0
  scope                = azurerm_key_vault.region.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.s3gatewayserv[0].principal_id
}
