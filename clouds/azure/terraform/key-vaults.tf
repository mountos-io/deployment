# One Azure Key Vault per scope (hub, region). azure provider: this IS the
# cloud-native secret store — services read/write mountos--* secrets directly
# with their managed identities (VAULT_PROVIDER=azure). hashicorp provider:
# the vaults only deliver byo-Vault bootstrap material (CA + AppRole
# secret_id, see secrets.tf). Operator-only secrets (the provision-pg DB
# passwords) live in the HUB vault exclusively: the region vault carries
# vault-scoped service grants in azure mode (region-iam.tf), so nothing
# operator-only may live there.

data "azurerm_client_config" "current" {}

# Random (not derived from the static resource group id) so a destroy +
# immediate redeploy in the same subscription doesn't collide with the
# vault's own name during its 30-day soft-delete/purge-protection window.
resource "random_id" "vault_suffix" {
  byte_length = 4
}

resource "azurerm_key_vault" "hub" {
  name                       = "mountos-hub-${random_id.vault_suffix.hex}" # globally unique
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 30
}

resource "azurerm_key_vault" "region" {
  name                       = "mountos-rgn-${random_id.vault_suffix.hex}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 30
}

output "key_vault_ids" {
  value = {
    hub    = azurerm_key_vault.hub.id
    region = azurerm_key_vault.region.id
  }
}
