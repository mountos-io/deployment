# mountos-admin-client, optional (var.admin_client_enabled). One direct-IP VM
# with its own static public IP, in the public subnet, on its own domain
# (admin_domain, not hub_domain, so it has a separate WebAuthn origin). Caddy
# gets a real Let's Encrypt certificate and reverse-proxies to the Node
# gateway on 127.0.0.1:3001 (plain HTTP inside the VM). The source is public
# (github.com/mountos-io/mountos-admin-client). The VM clones the repo and
# unpacks its committed production build, it does not compile anything.

locals {
  # Secret written by seed-vault.sh (kv_put admin-client) to the hub Key Vault.
  admin_client_secret_name = "${local.name_root}--admin-client"
}

resource "azurerm_network_security_group" "admin_client" {
  count               = var.admin_client_enabled ? 1 : 0
  name                = "${local.name_root}-admin-client"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_network_security_rule" "admin_client_https" {
  count                       = var.admin_client_enabled ? 1 : 0
  name                        = "admin-client-https"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.admin_client[0].name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.client_cidr # operator HTTPS (Caddy)
  destination_address_prefix  = "*"
}

# The Let's Encrypt HTTP-01 challenge comes from validation servers on
# changing addresses, so port 80 must be open to the whole Internet.
resource "azurerm_network_security_rule" "admin_client_http_acme" {
  count                       = var.admin_client_enabled ? 1 : 0
  name                        = "admin-client-http-acme"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.admin_client[0].name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
}

# Azure's default rules allow all VNet-internal inbound traffic. This closes
# that path so only the two rules above reach the VM.
resource "azurerm_network_security_rule" "admin_client_deny_other" {
  count                       = var.admin_client_enabled ? 1 : 0
  name                        = "admin-client-deny-other"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.admin_client[0].name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_public_ip" "admin_client" {
  count               = var.admin_client_enabled ? 1 : 0
  name                = "${local.name_root}-admin-client"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = [var.zones[0]]
}

resource "azurerm_network_interface" "admin_client" {
  count               = var.admin_client_enabled ? 1 : 0
  name                = "${local.name_root}-admin-client"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.admin_client[0].id
  }
}

resource "azurerm_network_interface_security_group_association" "admin_client" {
  count                     = var.admin_client_enabled ? 1 : 0
  network_interface_id      = azurerm_network_interface.admin_client[0].id
  network_security_group_id = azurerm_network_security_group.admin_client[0].id
}

resource "azurerm_linux_virtual_machine" "admin_client" {
  count                 = var.admin_client_enabled ? 1 : 0
  name                  = "${local.name_root}-admin-client"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = var.admin_client_vm_size
  admin_username        = "mosadmin"
  network_interface_ids = [azurerm_network_interface.admin_client[0].id]
  zone                  = var.zones[0]

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

  # System-assigned: this identity reads one secret and nothing else, so it
  # is created and removed with the VM.
  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.admin.sh.tftpl", {
    key_vault_uri = azurerm_key_vault.hub.vault_uri
    secret_name   = local.admin_client_secret_name
    admin_domain  = var.admin_domain
    hub_domain    = var.hub_domain
  }))

  lifecycle {
    precondition {
      condition     = var.vault_provider == "azure"
      error_message = "admin_client_enabled currently only supports vault_provider = azure (Key Vault). The hashicorp path is not wired for the admin-client secret yet."
    }
  }
}

# Read access to the admin-client secret only. The hub Key Vault also holds
# the DB passwords and the appserv secrets, which this VM must never read.
# The identity exists only after the VM, so the VM cannot depend on this
# grant. Role assignments take a short time to propagate, and the boot-time
# secret fetch retries until the grant is live.
resource "azurerm_role_assignment" "admin_client_secret_reader" {
  count                            = var.admin_client_enabled ? 1 : 0
  scope                            = "${azurerm_key_vault.hub.id}/secrets/${local.admin_client_secret_name}"
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_linux_virtual_machine.admin_client[0].identity[0].principal_id
  skip_service_principal_aad_check = true
}
