# ---------- appserv: reads the hub Key Vault only, per-secret grants ----------
resource "azurerm_user_assigned_identity" "appserv" {
  name                = "mountos-appserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# hashicorp provider: byo-Vault bootstrap material (CA + AppRole secret_id).
# Scoped to the individual secret paths, not the vault (see region-iam.tf's
# header comment for why) - the hub Key Vault also holds
# mountos-admin-db-password and mountos-region-db-password (rds.tf,
# region-rds.tf), which no service may ever read.
resource "azurerm_role_assignment" "appserv_ca_reader" {
  count                = local.hub_hashicorp ? 1 : 0
  scope                = "${azurerm_key_vault.hub.id}/secrets/mountos-hub-vault-ca"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appserv.principal_id
}

resource "azurerm_role_assignment" "appserv_secret_id_reader" {
  count                = local.hub_hashicorp ? 1 : 0
  scope                = "${azurerm_key_vault.hub.id}/secrets/mountos-appserv-vault-secret-id"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appserv.principal_id
}

# ---------- cloud-native secret store (vault_provider = azure) ----------
# appserv reads the hub Key Vault directly (VAULT_PROVIDER=azure, managed
# identity). Per-secret grants keep the rest of the hub vault (DB passwords,
# byo-Vault material) out of reach — in particular appserv can NEVER read
# mountos--api-master, which lives in the REGION vault appserv has no grants
# on. mountos--ping-probe is the store's health-probe name: authorizing that
# path turns the probe's 403 into the 404 SecretStore.Ping treats as healthy
# (the secret itself never exists; Azure RBAC resolves secret-path scopes at
# access time).
resource "azurerm_role_assignment" "appserv_secretstore" {
  for_each = var.vault_provider == "azure" ? toset([
    "mountos--appserv",
    "mountos--service-verifiers",
    "mountos--ping-probe",
  ]) : toset([])
  scope                = "${azurerm_key_vault.hub.id}/secrets/${each.value}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appserv.principal_id
}
