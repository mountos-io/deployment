output "key_vault_name" {
  description = "Pass to seed-keyvault.sh."
  value       = azurerm_key_vault.main.name
}

output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "member_public_ips" {
  description = "Per member block_volume_id. Allow each address on the hub SRPC port (AWS hub: external_block_cidrs as <ip>/32)."
  value       = { for k, ip in azurerm_public_ip.member : k => ip.ip_address }
}

output "storage_account" {
  description = "Blob account for the block storage entry. Container: mountos-azblock. Read the key with: az storage account keys list --account-name <name> --query '[0].value' -o tsv"
  value       = var.create_blob_storage ? azurerm_storage_account.blocks[0].name : null
}
