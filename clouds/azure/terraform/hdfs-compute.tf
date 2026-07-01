resource "azurerm_public_ip_prefix" "hdfsserv" {
  count               = var.hdfs_enable ? 1 : 0
  name                = "mountos-hdfsserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  prefix_length       = 28
  zones               = var.zones
}

resource "azurerm_linux_virtual_machine_scale_set" "hdfsserv" {
  count               = var.hdfs_enable ? 1 : 0
  name                = "mountos-hdfsserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.hdfs_vm_size
  instances           = var.hdfs_count
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
    identity_ids = [azurerm_user_assigned_identity.hdfsserv[0].id]
  }

  network_interface {
    name                      = "mountos-hdfsserv"
    primary                   = true
    network_security_group_id = local.region_nsg_id

    ip_configuration {
      name                           = "internal"
      primary                        = true
      subnet_id                      = local.region_public_subnet.id
      application_security_group_ids = [azurerm_application_security_group.gateway.id]
      public_ip_address {
        name                = "public"
        public_ip_prefix_id = azurerm_public_ip_prefix.hdfsserv[0].id
      }
    }
  }

  custom_data = base64encode(templatefile("${path.module}/hdfs-cloud-init.hdfsserv.sh.tftpl", {
    vault_addr              = local.region_vault_endpoint
    vault_role_id           = var.region_vault_role_id
    key_vault_uri           = azurerm_key_vault.region.vault_uri
    region_vault_ca_secret  = "mountos-region-vault-ca"
    region_secret_id_secret = "mountos-region-vault-secret-id"
    identity_client_id      = azurerm_user_assigned_identity.hdfsserv[0].client_id
    region_cluster_id       = var.region_cluster_id
    srpc_addr               = "${azurerm_lb.appserv_srpc.frontend_ip_configuration[0].private_ip_address}:9443"
    mos_version             = var.mos_version
    mos_installer_sha256    = var.mos_installer_sha256
  }))

  # No health_probe_id: falls back to VM provisioning-state only (see
  # region-compute.tf note on dataserv for the same pattern).
  automatic_instance_repair {
    enabled      = true
    grace_period = "PT10M"
  }

  upgrade_mode = "Rolling"
  rolling_upgrade_policy {
    max_batch_instance_percent              = 34
    max_unhealthy_instance_percent          = 34
    max_unhealthy_upgraded_instance_percent = 34
    pause_time_between_batches              = "PT0S"
  }

  depends_on = [
    azurerm_key_vault_secret.region_vault_secret_id,
    azurerm_role_assignment.hdfsserv_secrets_reader,
  ]
}
