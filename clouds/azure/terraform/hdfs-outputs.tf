output "hdfsserv_vmss" {
  value = var.hdfs_enable ? azurerm_linux_virtual_machine_scale_set.hdfsserv[0].name : null
}
