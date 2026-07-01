# ---------- vault node: azurekeyvault auto-unseal against the hub key (kms.tf) ----------
resource "azurerm_user_assigned_identity" "vault" {
  count               = local.self_vault ? 1 : 0
  name                = "mountos-vault"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# Publish the self-signed TLS CA to Key Vault so appserv can trust Vault.
resource "azurerm_role_assignment" "vault_ca_writer" {
  count                = local.self_vault ? 1 : 0
  scope                = azurerm_key_vault.hub.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.vault[0].principal_id
}

# ---------- appserv: reaches Vault over the network, no KMS ----------
resource "azurerm_user_assigned_identity" "appserv" {
  name                = "mountos-appserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "appserv_secrets_reader" {
  scope                = azurerm_key_vault.hub.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appserv.principal_id
}
