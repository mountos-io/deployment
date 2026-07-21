# Region DB (mountos_data) on Postgres Flexible Server. Provisioned only when
# region_db_mode = provision-pg. Separate from the hub admin DB per mountOS
# topology. See rds.tf for the manage_master_user_password PARITY GAP note —
# same caveat applies here.

resource "random_password" "region_db" {
  count            = local.region_provision_pg ? 1 : 0
  length           = 32
  special          = true
  override_special = "-_"
}

# Stored in the HUB Key Vault, not the region one: in azure secret-store mode
# the region vault carries VAULT-SCOPED service grants (region-iam.tf), so an
# operator-only credential there would be service-readable. The hub vault only
# ever gets per-secret grants, keeping this out of every service's reach.
resource "azurerm_key_vault_secret" "region_db_password" {
  count        = local.region_provision_pg ? 1 : 0
  name         = "${local.name_root}-region-db-password"
  value        = random_password.region_db[0].result
  key_vault_id = azurerm_key_vault.hub.id
}

# Delegated subnet + private DNS zone, in the SAME network as the region's
# other resources (shared: hub VNet; dedicated: region VNet).
resource "azurerm_subnet" "region_db" {
  count                = local.region_provision_pg ? 1 : 0
  name                 = "${local.name_root}-region-db"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = local.region_dedicated_vnet ? azurerm_virtual_network.region[0].name : azurerm_virtual_network.main.name
  address_prefixes     = [local.region_dedicated_vnet ? "10.1.20.0/24" : "10.0.21.0/24"]

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "region_db" {
  count               = local.region_provision_pg ? 1 : 0
  name                = "${local.name_root}-region.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "region_db" {
  count                 = local.region_provision_pg ? 1 : 0
  name                  = "${local.name_root}-region-db-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.region_db[0].name
  virtual_network_id    = local.region_network
}

resource "azurerm_postgresql_flexible_server" "region" {
  count                  = local.region_provision_pg ? 1 : 0
  name                   = "${local.name_root}-region"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = var.region_db_provider_version
  sku_name               = var.region_db_sku
  storage_mb             = var.region_db_storage_gb * 1024
  administrator_login    = var.region_db_username
  administrator_password = random_password.region_db[0].result
  zone                   = var.mode == "production" ? var.zones[0] : null
  high_availability {
    mode = var.mode == "production" ? "ZoneRedundant" : "Disabled"
  }
  backup_retention_days        = 14
  geo_redundant_backup_enabled = var.mode == "production"
  delegated_subnet_id          = azurerm_subnet.region_db[0].id
  private_dns_zone_id          = azurerm_private_dns_zone.region_db[0].id

  # Kept unconditional: see rds.tf's admin resource for why (no
  # deletion_protection-equivalent attribute exists on this resource type).
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.region_db]
}

resource "azurerm_postgresql_flexible_server_database" "region" {
  count     = local.region_provision_pg ? 1 : 0
  name      = "mountos_data"
  server_id = azurerm_postgresql_flexible_server.region[0].id
}

# Server-side TLS enforcement (see rds.tf's admin config for why).
resource "azurerm_postgresql_flexible_server_configuration" "region_require_tls" {
  count     = local.region_provision_pg ? 1 : 0
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.region[0].id
  value     = "ON"
}
