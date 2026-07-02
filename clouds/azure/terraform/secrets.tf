# hashicorp provider only: byo-Vault bootstrap material delivered to instances
# via Key Vault (mirrors AWS's SSM SecureString pattern). The secret_id
# secrets get a terraform-managed version only when the corresponding var is
# set — absent on a first apply before the seed runs; cloud-init's
# ExecStartPre fetch tolerates that and retries. The azure provider needs none
# of this: services read the store directly with their managed identities.

resource "azurerm_key_vault_secret" "appserv_vault_secret_id" {
  count        = local.hub_hashicorp && var.vault_secret_id != "" ? 1 : 0
  name         = "mountos-appserv-vault-secret-id"
  value        = var.vault_secret_id
  key_vault_id = azurerm_key_vault.hub.id
}

resource "azurerm_key_vault_secret" "region_vault_secret_id" {
  count        = local.region_hashicorp && var.region_vault_secret_id != "" ? 1 : 0
  name         = "mountos-region-vault-secret-id"
  value        = var.region_vault_secret_id
  key_vault_id = azurerm_key_vault.region.id
}

# byo Vault with a PRIVATE CA: Terraform publishes the operator-supplied CA so
# instances can trust it. Public-CA byo Vaults leave the pem empty (instances
# then use system CAs and skip the fetch). The secret-scoped CA-reader role
# assignments (iam.tf/region-iam.tf) cover these paths.
resource "azurerm_key_vault_secret" "hub_vault_ca_byo" {
  count        = local.hub_hashicorp && var.vault_ca_pem != "" ? 1 : 0
  name         = "mountos-hub-vault-ca"
  value        = var.vault_ca_pem
  key_vault_id = azurerm_key_vault.hub.id
}

resource "azurerm_key_vault_secret" "region_vault_ca_byo" {
  count        = local.region_hashicorp && var.region_vault_ca_pem != "" ? 1 : 0
  name         = "mountos-region-vault-ca"
  value        = var.region_vault_ca_pem
  key_vault_id = azurerm_key_vault.region.id
}
