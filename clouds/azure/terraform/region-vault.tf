# Self-hosted region Vault node (single raft peer). Provisioned only when
# region_vault_hosting = self-hosted. All region-scoped services read their
# own config from this Vault at startup (VAULT_HASHICORP_ADDRESS is a runtime
# env var, not just a boot-time fetch) — dataserv, blockserv, and the
# hdfsserv/s3gatewayserv gateway ASG all need real network access, not just
# dataserv (a bug the AWS module shipped once and had to fix later — baked in
# correctly here from the start).

resource "azurerm_user_assigned_identity" "region_vault" {
  count               = local.region_self_vault ? 1 : 0
  name                = "mountos-region-vault"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "region_vault_secrets_writer" {
  count                = local.region_self_vault ? 1 : 0
  scope                = azurerm_key_vault.region.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.region_vault[0].principal_id
}

resource "azurerm_role_assignment" "region_vault_kms_user" {
  count                = local.region_self_vault ? 1 : 0
  scope                = azurerm_key_vault_key.region.resource_versionless_id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.region_vault[0].principal_id
}

resource "azurerm_application_security_group" "region_vault" {
  count               = local.region_self_vault ? 1 : 0
  name                = "mountos-region-vault"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_network_security_rule" "region_vault_api_from_dataserv" {
  count                                      = local.region_self_vault ? 1 : 0
  name                                       = "region-vault-api-from-dataserv"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 200
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8200"
  source_application_security_group_ids      = [azurerm_application_security_group.dataserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.region_vault[0].id]
}

resource "azurerm_network_security_rule" "region_vault_api_from_blockserv" {
  count                                      = local.region_self_vault ? 1 : 0
  name                                       = "region-vault-api-from-blockserv"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 201
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8200"
  source_application_security_group_ids      = [azurerm_application_security_group.blockserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.region_vault[0].id]
}

resource "azurerm_network_security_rule" "region_vault_api_from_gateway" {
  count                                      = local.region_self_vault ? 1 : 0
  name                                       = "region-vault-api-from-gateway"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 202
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8200"
  source_application_security_group_ids      = [azurerm_application_security_group.gateway.id]
  destination_application_security_group_ids = [azurerm_application_security_group.region_vault[0].id]
}

resource "azurerm_network_security_rule" "region_vault_raft_self" {
  count                                      = local.region_self_vault ? 1 : 0
  name                                       = "region-vault-raft-self"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 203
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8201"
  source_application_security_group_ids      = [azurerm_application_security_group.region_vault[0].id]
  destination_application_security_group_ids = [azurerm_application_security_group.region_vault[0].id]
}

resource "azurerm_network_interface" "region_vault" {
  count               = local.region_self_vault ? 1 : 0
  name                = "mountos-region-vault"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.region_private_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_application_security_group_association" "region_vault" {
  count                         = local.region_self_vault ? 1 : 0
  network_interface_id          = azurerm_network_interface.region_vault[0].id
  application_security_group_id = azurerm_application_security_group.region_vault[0].id
}

resource "azurerm_network_interface_security_group_association" "region_vault" {
  count                     = local.region_self_vault ? 1 : 0
  network_interface_id      = azurerm_network_interface.region_vault[0].id
  network_security_group_id = local.region_nsg_id
}

resource "azurerm_linux_virtual_machine" "region_vault" {
  count                 = local.region_self_vault ? 1 : 0
  name                  = "mountos-region-vault"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = var.region_vault_vm_size
  admin_username        = "mosadmin"
  network_interface_ids = [azurerm_network_interface.region_vault[0].id]
  zone                  = var.zones[0]

  # Trusted Launch + encryption-at-host: see vault.tf's resource for why this
  # is safe (arm64 image is Gen2-only).
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
    identity_ids = [azurerm_user_assigned_identity.region_vault[0].id]
  }

  custom_data = base64encode(templatefile("${path.module}/region-vault-init.sh.tftpl", {
    key_vault_uri      = azurerm_key_vault.region.vault_uri
    key_vault_name     = azurerm_key_vault.region.name
    key_name           = azurerm_key_vault_key.region.name
    ca_secret          = "mountos-region-vault-ca"
    identity_client_id = azurerm_user_assigned_identity.region_vault[0].client_id
  }))

  depends_on = [
    azurerm_role_assignment.region_vault_secrets_writer,
    azurerm_role_assignment.region_vault_kms_user,
  ]
}
