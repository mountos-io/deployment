# Self-hosted Vault node (single raft peer). Provisioned only when vault_hosting = self-hosted.
# HA: scale to 3 raft peers later (see vault-init.sh.tftpl note).

resource "azurerm_network_interface" "vault" {
  count               = local.self_vault ? 1 : 0
  name                = "mountos-vault"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_application_security_group" "vault" {
  count               = local.self_vault ? 1 : 0
  name                = "mountos-vault"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_network_interface_application_security_group_association" "vault" {
  count                         = local.self_vault ? 1 : 0
  network_interface_id          = azurerm_network_interface.vault[0].id
  application_security_group_id = azurerm_application_security_group.vault[0].id
}

resource "azurerm_network_security_rule" "vault_api_from_appserv" {
  count                                      = local.self_vault ? 1 : 0
  name                                       = "vault-api-from-appserv"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.hub.name
  priority                                   = 200
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8200"
  source_application_security_group_ids      = [azurerm_application_security_group.appserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.vault[0].id]
}

resource "azurerm_network_security_rule" "vault_raft_self" {
  count                                      = local.self_vault ? 1 : 0
  name                                       = "vault-raft-self"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.hub.name
  priority                                   = 201
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8201"
  source_application_security_group_ids      = [azurerm_application_security_group.vault[0].id]
  destination_application_security_group_ids = [azurerm_application_security_group.vault[0].id]
}

resource "azurerm_network_interface_security_group_association" "vault" {
  count                     = local.self_vault ? 1 : 0
  network_interface_id      = azurerm_network_interface.vault[0].id
  network_security_group_id = azurerm_network_security_group.hub.id
}

resource "azurerm_linux_virtual_machine" "vault" {
  count                 = local.self_vault ? 1 : 0
  name                  = "mountos-vault"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = var.vault_vm_size
  admin_username        = "mosadmin"
  network_interface_ids = [azurerm_network_interface.vault[0].id]
  zone                  = var.zones[0]

  # Trusted Launch (secure boot + vTPM) + encryption-at-host: safe here since
  # the arm64 image (data.tf's local.image_reference) is Gen2-only by
  # construction — Azure has no Gen1 path for Arm64 VMs at all, so image-
  # generation compatibility isn't a live risk the way it would be for an
  # x86 image that could resolve to either generation.
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = true

  # Password auth is disabled; login is via the managed identity + cloud-init
  # only (no operator SSH key baked in by default). Set admin_ssh_key if you
  # need interactive SSH access.
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
    identity_ids = [azurerm_user_assigned_identity.vault[0].id]
  }

  custom_data = base64encode(templatefile("${path.module}/vault-init.sh.tftpl", {
    key_vault_uri      = azurerm_key_vault.hub.vault_uri
    key_vault_name     = azurerm_key_vault.hub.name
    key_name           = azurerm_key_vault_key.hub.name
    ca_secret          = "mountos-hub-vault-ca"
    identity_client_id = azurerm_user_assigned_identity.vault[0].client_id
  }))

  # RBAC role assignments have a propagation window; submit both grants before
  # boot so Vault's own retry-driven startup (systemd Restart=on-failure) has
  # the best chance of succeeding without waiting out a cold 403.
  depends_on = [
    azurerm_role_assignment.hub_vault_kms,
    azurerm_role_assignment.vault_ca_writer,
  ]
}
