output "region_vault_addr" {
  value = local.region_vault_endpoint
}

output "dataserv_vmss" {
  value = azurerm_linux_virtual_machine_scale_set.dataserv.name
}
