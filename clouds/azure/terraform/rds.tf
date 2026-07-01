# Admin DB (mountos_admin) on Postgres Flexible Server. Provisioned only when
# admin_db_mode = provision-pg.
#
# PARITY GAP vs AWS: RDS has manage_master_user_password (AWS-managed, rotated,
# NEVER a Terraform value). Postgres Flexible Server has no equivalent for
# password auth — same gap already documented for GCP's Cloud SQL. Generated
# via random_password and stored in Key Vault; this DOES make the password a
# Terraform value (present in tfstate), unlike AWS.
resource "random_password" "admin_db" {
  count            = local.provision_pg ? 1 : 0
  length           = 32
  special          = true
  override_special = "-_"
}

resource "azurerm_key_vault_secret" "admin_db_password" {
  count        = local.provision_pg ? 1 : 0
  name         = "mountos-admin-db-password"
  value        = random_password.admin_db[0].result
  key_vault_id = azurerm_key_vault.hub.id
}

# Postgres Flexible Server private access needs a delegated subnet + a private
# DNS zone linked to the VNet.
resource "azurerm_subnet" "admin_db" {
  count                = local.provision_pg ? 1 : 0
  name                 = "mountos-admin-db"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.20.0/24"]

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "admin_db" {
  count               = local.provision_pg ? 1 : 0
  name                = "mountos-admin.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "admin_db" {
  count                 = local.provision_pg ? 1 : 0
  name                  = "mountos-admin-db-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.admin_db[0].name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_postgresql_flexible_server" "admin" {
  count                  = local.provision_pg ? 1 : 0
  name                   = "mountos-admin"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = var.admin_db_provider_version
  sku_name               = var.db_sku
  storage_mb             = var.db_storage_gb
  administrator_login    = var.db_username
  administrator_password = random_password.admin_db[0].result
  zone                   = var.mode == "production" ? var.zones[0] : null
  high_availability {
    mode = var.mode == "production" ? "ZoneRedundant" : "Disabled"
  }
  backup_retention_days        = 14
  geo_redundant_backup_enabled = var.mode == "production"
  delegated_subnet_id          = azurerm_subnet.admin_db[0].id
  private_dns_zone_id          = azurerm_private_dns_zone.admin_db[0].id

  # Kept unconditional (unlike AWS/GCP's mode-gated equivalent): Postgres
  # Flexible Server has no deletion_protection-equivalent attribute in the
  # azurerm provider, so this is the only Terraform-level backstop against an
  # accidental destroy in ANY mode. Dev/staging teardown needs
  # `terraform state rm` on Azure specifically.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.admin_db]
}

resource "azurerm_postgresql_flexible_server_database" "admin" {
  count     = local.provision_pg ? 1 : 0
  name      = "mountos_admin"
  server_id = azurerm_postgresql_flexible_server.admin[0].id
}

# Server-side TLS enforcement: bootstrap DSN construction already sets
# sslmode=require, but that's client-side only. Flexible Server defaults this
# to ON already, but pin it explicitly so Terraform catches drift.
resource "azurerm_postgresql_flexible_server_configuration" "admin_require_tls" {
  count     = local.provision_pg ? 1 : 0
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.admin[0].id
  value     = "ON"
}
