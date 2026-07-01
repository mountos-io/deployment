# One managed identity per region service (dataserv/gcserv co-located,
# blockserv, hdfsserv+s3gatewayserv share the "gateway" tier the same way they
# share an ASG) — blast-radius isolation, matching the AWS module's
# per-service IAM role even where services share a security group/tag. All
# read the same region Key Vault CA + AppRole secret_id (same region AppRole).

resource "azurerm_user_assigned_identity" "dataserv" {
  name                = "mountos-dataserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "dataserv_secrets_reader" {
  scope                = azurerm_key_vault.region.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.dataserv.principal_id
}

resource "azurerm_user_assigned_identity" "blockserv" {
  count               = var.block_enable ? 1 : 0
  name                = "mountos-blockserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "blockserv_secrets_reader" {
  count                = var.block_enable ? 1 : 0
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

resource "azurerm_role_assignment" "hdfsserv_secrets_reader" {
  count                = var.hdfs_enable ? 1 : 0
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

resource "azurerm_role_assignment" "s3gatewayserv_secrets_reader" {
  count                = var.s3gateway_enable ? 1 : 0
  scope                = azurerm_key_vault.region.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.s3gatewayserv[0].principal_id
}
