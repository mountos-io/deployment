# Azure Key Vault serves BOTH roles AWS/GCP split into two services: KMS keys
# (Vault auto-unseal, azurekeyvault seal) AND secrets (CA/AppRole secret_id
# delivery, see secrets.tf) — one Key Vault per scope holds both.

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

resource "azurerm_key_vault_key" "hub" {
  name         = "mountos-hub"
  key_vault_id = azurerm_key_vault.hub.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["wrapKey", "unwrapKey"]

  rotation_policy {
    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "hub_vault_kms" {
  count                = local.self_vault ? 1 : 0
  scope                = azurerm_key_vault_key.hub.resource_versionless_id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.vault[0].principal_id
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

resource "azurerm_key_vault_key" "region" {
  name         = "mountos-region"
  key_vault_id = azurerm_key_vault.region.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["wrapKey", "unwrapKey"]

  rotation_policy {
    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "region_vault_kms" {
  count                = local.region_self_vault ? 1 : 0
  scope                = azurerm_key_vault_key.region.resource_versionless_id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.region_vault[0].principal_id
}

output "key_vault_ids" {
  value = {
    hub    = azurerm_key_vault.hub.id
    region = azurerm_key_vault.region.id
  }
}
