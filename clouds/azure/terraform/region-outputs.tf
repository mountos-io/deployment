# No region_vault_addr output: the azure provider needs none (Key Vault,
# managed identities); the hashicorp provider's address is the
# operator-supplied var.region_vault_addr.

# Region Key Vault URL — the region seed's REGION_VAULT_AZURE_URL (azure provider).
output "region_key_vault_url" {
  value = azurerm_key_vault.region.vault_uri
}

# No DSN output: a DSN is never a Terraform value (see outputs.tf's admin note).
# provision-pg: build the DSN from region_db_host + the Key Vault password
# secret (region_db_secret_id), then set REGION_DB_URL for region-seed.sh.
# byo: the operator sets REGION_DB_URL in the region-seed environment.
output "region_db_host" {
  value = local.region_provision_pg ? azurerm_postgresql_flexible_server.region[0].fqdn : null
}

output "region_db_secret_id" {
  value = local.region_provision_pg ? azurerm_key_vault_secret.region_db_password[0].versionless_id : null
}

output "dataserv_vmss" {
  value = azurerm_linux_virtual_machine_scale_set.dataserv.name
}
