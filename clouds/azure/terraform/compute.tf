resource "azurerm_linux_virtual_machine_scale_set" "appserv" {
  name                = "mountos-appserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.appserv_vm_size
  instances           = var.appserv_count
  zones               = var.zones
  admin_username      = "mosadmin"

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
    identity_ids = [azurerm_user_assigned_identity.appserv.id]
  }

  network_interface {
    name                      = "mountos-appserv"
    primary                   = true
    network_security_group_id = azurerm_network_security_group.hub.id

    ip_configuration {
      name                                         = "internal"
      primary                                      = true
      subnet_id                                    = azurerm_subnet.private.id
      application_security_group_ids               = [azurerm_application_security_group.appserv.id]
      load_balancer_backend_address_pool_ids       = [azurerm_lb_backend_address_pool.appserv_srpc.id]
      application_gateway_backend_address_pool_ids = [for p in azurerm_application_gateway.hub.backend_address_pool : p.id if p.name == "appserv"]
    }
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.appserv.sh.tftpl", {
    vault_addr               = local.vault_endpoint
    vault_role_id            = var.vault_role_id
    key_vault_uri            = azurerm_key_vault.hub.vault_uri
    hub_vault_ca_secret      = "mountos-hub-vault-ca"
    appserv_secret_id_secret = "mountos-appserv-vault-secret-id"
    identity_client_id       = azurerm_user_assigned_identity.appserv.client_id
    mos_version              = var.mos_version
    mos_installer_sha256     = var.mos_installer_sha256
  }))

  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M"
  }

  upgrade_mode = "Rolling"
  rolling_upgrade_policy {
    max_batch_instance_percent              = 50
    max_unhealthy_instance_percent          = 50
    max_unhealthy_upgraded_instance_percent = 50
    pause_time_between_batches              = "PT0S"
  }

  health_probe_id = azurerm_lb_probe.appserv_health.id

  # Both the secret's existence AND the RBAC grant to read it: Key Vault role
  # assignments have a documented eventual-consistency propagation window, so
  # this ordering doesn't guarantee no race, but it does guarantee the grant
  # is at least submitted before boot starts (ExecStartPre retries on 403).
  depends_on = [
    azurerm_key_vault_secret.appserv_vault_secret_id,
    azurerm_role_assignment.appserv_secrets_reader,
  ]
}
