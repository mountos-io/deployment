# blockserv data-plane members. Each member is a distinct azurerm_linux_virtual_machine
# with its own BLOCK_VOLUME_ID and its own cache disk, spread across zones.
# Each gets a stable static Public IP (not ephemeral): unlike the VMSS-based
# fleets, blockserv members are individually addressed by a persistent
# BLOCK_VOLUME_ID and aren't expected to churn via rolling replacement, so a
# stable address avoids unnecessary re-discovery.

resource "azurerm_public_ip" "blockserv" {
  for_each            = local.block_members_map
  name                = "${local.name_root}-blockserv-${each.key}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = [var.zones[each.value.zone_index % length(var.zones)]]
}

resource "azurerm_managed_disk" "blockserv_cache" {
  for_each             = local.block_members_map
  name                 = "${local.name_root}-blockserv-cache-${each.key}"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.block_cache_gb
  zone                 = var.zones[each.value.zone_index % length(var.zones)]
}

resource "azurerm_network_interface" "blockserv" {
  for_each            = local.block_members_map
  name                = "${local.name_root}-blockserv-${each.key}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.region_public_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.blockserv[each.key].id
  }
}

resource "azurerm_network_interface_application_security_group_association" "blockserv" {
  for_each                      = local.block_members_map
  network_interface_id          = azurerm_network_interface.blockserv[each.key].id
  application_security_group_id = azurerm_application_security_group.blockserv.id
}

resource "azurerm_network_interface_security_group_association" "blockserv" {
  for_each                  = local.block_members_map
  network_interface_id      = azurerm_network_interface.blockserv[each.key].id
  network_security_group_id = local.region_nsg_id
}

resource "azurerm_linux_virtual_machine" "blockserv" {
  for_each              = local.block_members_map
  name                  = "${local.name_root}-blockserv-${each.key}"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = var.block_vm_size
  admin_username        = "mosadmin"
  network_interface_ids = [azurerm_network_interface.blockserv[each.key].id]
  zone                  = var.zones[each.value.zone_index % length(var.zones)]

  # Trusted Launch + encryption-at-host: see compute.tf's appserv resource for
  # why this is safe (arm64 image is Gen2-only).
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = true

  disable_password_authentication = true
  admin_ssh_key {
    username   = "mosadmin"
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = local.image_reference.publisher
    offer     = local.image_reference.offer
    sku       = local.image_reference.sku
    version   = local.image_reference.version
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.blockserv[0].id]
  }

  custom_data = base64encode(templatefile("${path.module}/block-cloud-init.blockserv.sh.tftpl", {
    vault_provider          = var.region_vault_provider
    vault_addr              = var.region_vault_addr
    vault_role_id           = var.region_vault_role_id
    vault_ca_source         = local.region_vault_ca_source
    key_vault_uri           = azurerm_key_vault.region.vault_uri
    region_vault_ca_secret  = "${local.name_root}-region-vault-ca"
    region_secret_id_secret = "${local.name_root}-region-vault-secret-id"
    identity_client_id      = azurerm_user_assigned_identity.blockserv[0].client_id
    region_cluster_id       = var.region_cluster_id
    srpc_addr               = "${azurerm_lb.appserv_srpc.frontend_ip_configuration[0].private_ip_address}:9443"
    advertise_addr          = azurerm_public_ip.blockserv[each.key].ip_address
    block_volume_id         = each.value.block_volume_id
    delete_mode             = var.block_delete_mode
    mos_version             = var.mos_version
    mos_installer_sha256    = var.mos_installer_sha256
  }))

  depends_on = [
    azurerm_key_vault_secret.region_vault_secret_id,
    azurerm_key_vault_secret.region_vault_ca_byo,
    azurerm_role_assignment.blockserv_ca_reader,
    azurerm_role_assignment.blockserv_secret_id_reader,
    azurerm_role_assignment.blockserv_secretstore,
  ]
}

resource "azurerm_virtual_machine_data_disk_attachment" "blockserv_cache" {
  for_each           = local.block_members_map
  managed_disk_id    = azurerm_managed_disk.blockserv_cache[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.blockserv[each.key].id
  lun                = 0
  caching            = "ReadWrite"
}
