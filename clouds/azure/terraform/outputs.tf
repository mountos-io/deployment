output "hub_url" {
  value = "https://${var.hub_domain}"
}

output "lb_ip" {
  value = azurerm_public_ip.appgw.ip_address
}

# No vault_addr output: the azure provider needs none (Key Vault, managed
# identities); the hashicorp provider's address is the operator-supplied
# var.vault_addr.

# Hub Key Vault URL — the seed scripts' VAULT_AZURE_URL (azure provider).
output "hub_key_vault_url" {
  value = azurerm_key_vault.hub.vault_uri
}

# No DSN output: a DSN is never a Terraform value (it would land in tfstate;
# the provision-pg password already does via random_password — rds.tf's PARITY
# GAP — but the full credential URL never should). provision-pg: build the DSN
# from admin_db_host + the Key Vault password secret, e.g.
#   az keyvault secret show --id <admin_db_secret_id> --query value -o tsv
# then set ADMIN_DB_URL for the seed step. byo: the operator sets ADMIN_DB_URL
# in answers.env for the seed step.
output "admin_db_host" {
  value = local.provision_pg ? azurerm_postgresql_flexible_server.admin[0].fqdn : null
}

output "admin_db_secret_id" {
  value = local.provision_pg ? azurerm_key_vault_secret.admin_db_password[0].versionless_id : null
}

output "resource_group" {
  value = azurerm_resource_group.main.name
}
