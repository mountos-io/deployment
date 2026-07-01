# Key Vault secrets. The vault-ca secrets hold NO terraform-managed version —
# the Vault instance publishes its self-signed CA as a version at boot (see
# vault-init.sh.tftpl). The secret_id secrets get a terraform-managed version
# only when the corresponding var is set (mirrors AWS's SSM SecureString
# pattern — absent on a first apply before the seed runs; cloud-init tolerates
# that).

resource "azurerm_key_vault_secret" "appserv_vault_secret_id" {
  count        = var.vault_secret_id != "" ? 1 : 0
  name         = "mountos-appserv-vault-secret-id"
  value        = var.vault_secret_id
  key_vault_id = azurerm_key_vault.hub.id
}

resource "azurerm_key_vault_secret" "region_vault_secret_id" {
  count        = var.region_vault_secret_id != "" ? 1 : 0
  name         = "mountos-region-vault-secret-id"
  value        = var.region_vault_secret_id
  key_vault_id = azurerm_key_vault.region.id
}
