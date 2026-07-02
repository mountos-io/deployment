# dataserv fleet (+ co-located gcserv). Registers with the hub over SRPC at
# the hub internal LB; reaches the region Vault over the network (no KMS on
# dataserv). PUBLIC subnet: dataserv advertises a public IPv4 (see
# region-cloud-init).

resource "azurerm_public_ip_prefix" "dataserv" {
  name                = "mountos-dataserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  prefix_length       = 28 # 16 addresses, enough headroom for dataserv_count + rolling updates
  zones               = var.zones
}

resource "azurerm_linux_virtual_machine_scale_set" "dataserv" {
  name                = "mountos-dataserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.dataserv_vm_size
  instances           = var.dataserv_count
  zones               = var.zones
  admin_username      = "mosadmin"

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

  # Raft data disk. Ephemeral per instance (delete_on_termination equivalent:
  # a scale-set-managed data disk is deleted with the instance by default) — a
  # replaced node rejoins quorum and re-syncs from peers; raft state is NOT
  # migrated across replacements.
  data_disk {
    lun                  = 0
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.raft_disk_gb
    create_option        = "Empty"
  }

  source_image_reference {
    publisher = local.image_reference.publisher
    offer     = local.image_reference.offer
    sku       = local.image_reference.sku
    version   = local.image_reference.version
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.dataserv.id]
  }

  network_interface {
    name                      = "mountos-dataserv"
    primary                   = true
    network_security_group_id = local.region_nsg_id

    ip_configuration {
      name                           = "internal"
      primary                        = true
      subnet_id                      = local.region_public_subnet.id
      application_security_group_ids = var.gcserv_colocated ? [azurerm_application_security_group.dataserv.id, azurerm_application_security_group.gcserv.id] : [azurerm_application_security_group.dataserv.id]
      public_ip_address {
        name                = "public"
        public_ip_prefix_id = azurerm_public_ip_prefix.dataserv.id
      }
    }
  }

  custom_data = base64encode(templatefile("${path.module}/region-cloud-init.dataserv.sh.tftpl", {
    vault_provider          = var.region_vault_provider
    vault_addr              = var.region_vault_addr
    vault_role_id           = var.region_vault_role_id
    vault_ca_source         = local.region_vault_ca_source
    key_vault_uri           = azurerm_key_vault.region.vault_uri
    region_vault_ca_secret  = "mountos-region-vault-ca"
    region_secret_id_secret = "mountos-region-vault-secret-id"
    identity_client_id      = azurerm_user_assigned_identity.dataserv.client_id
    region_cluster_id       = var.region_cluster_id
    srpc_addr               = "${azurerm_lb.appserv_srpc.frontend_ip_configuration[0].private_ip_address}:9443"
    arena_size              = var.arena_size
    mos_version             = var.mos_version
    mos_installer_sha256    = var.mos_installer_sha256
    gcserv_colocated        = var.gcserv_colocated
  }))

  # No health_probe_id: dataserv is not behind an LB. automatic_instance_repair
  # falls back to VM provisioning-state only (same as AWS's EC2-type health
  # check) - raft quorum handles peer-loss/replacement at the app layer, not
  # infra-triggered repair.
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
    azurerm_key_vault_secret.region_vault_ca_byo,
    azurerm_role_assignment.dataserv_ca_reader,
    azurerm_role_assignment.dataserv_secret_id_reader,
    azurerm_role_assignment.dataserv_secretstore,
  ]

  lifecycle {
    precondition {
      condition     = !local.region_hashicorp || var.region_vault_addr != ""
      error_message = "region_vault_provider = hashicorp requires region_vault_addr (the https address of your byo region Vault; this package never launches one)."
    }
    precondition {
      condition     = local.region_hashicorp || (var.region_vault_addr == "" && var.region_vault_ca_pem == "" && var.region_vault_role_id == "")
      error_message = "region_vault_addr/region_vault_ca_pem/region_vault_role_id are only for region_vault_provider = hashicorp — the azure provider uses Key Vault with managed identities."
    }
  }
}
