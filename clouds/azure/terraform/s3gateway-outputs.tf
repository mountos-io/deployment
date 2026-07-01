output "s3gatewayserv_vmss" {
  value = var.s3gateway_enable ? azurerm_linux_virtual_machine_scale_set.s3gatewayserv[0].name : null
}
