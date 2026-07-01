output "blockserv_instances" {
  value = { for k, ip in azurerm_public_ip.blockserv : k => ip.ip_address }
}
