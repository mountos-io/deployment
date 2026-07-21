resource "azurerm_linux_virtual_machine_scale_set" "appserv" {
  name                = "${local.name_root}-appserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.appserv_vm_size
  instances           = var.appserv_count
  zones               = var.zones
  admin_username      = "mosadmin"

  # Trusted Launch (secure boot + vTPM) + encryption-at-host: safe here since
  # the arm64 image (data.tf's local.image_reference) is Gen2-only by
  # construction — Azure has no Gen1 path for Arm64 VMs at all, so image-
  # generation compatibility isn't a live risk the way it would be for an
  # x86 image that could resolve to either generation. The other fleets
  # reference this rationale.
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
    name                      = "${local.name_root}-appserv"
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
    vault_provider           = var.vault_provider
    vault_addr               = var.vault_addr
    vault_role_id            = var.vault_role_id
    vault_ca_source          = local.hub_vault_ca_source
    key_vault_uri            = azurerm_key_vault.hub.vault_uri
    hub_vault_ca_secret      = "${local.name_root}-hub-vault-ca"
    appserv_secret_id_secret = "${local.name_root}-appserv-vault-secret-id"
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

  # Both the secrets' existence AND the RBAC grants to read them (whichever
  # provider mode instantiates them): Key Vault role assignments have a
  # documented eventual-consistency propagation window, so this ordering
  # doesn't guarantee no race, but it does guarantee the grant is at least
  # submitted before boot starts (hashicorp: ExecStartPre retries on 403;
  # azure: the service's own store retry loop does).
  depends_on = [
    azurerm_key_vault_secret.appserv_vault_secret_id,
    azurerm_key_vault_secret.hub_vault_ca_byo,
    azurerm_role_assignment.appserv_ca_reader,
    azurerm_role_assignment.appserv_secret_id_reader,
    azurerm_role_assignment.appserv_secretstore,
  ]

  lifecycle {
    precondition {
      condition     = !local.hub_hashicorp || var.vault_addr != ""
      error_message = "vault_provider = hashicorp requires vault_addr (the https address of your byo Vault; this package never launches one)."
    }
    precondition {
      condition     = local.hub_hashicorp || (var.vault_addr == "" && var.vault_ca_pem == "" && var.vault_role_id == "")
      error_message = "vault_addr/vault_ca_pem/vault_role_id are only for vault_provider = hashicorp — the azure provider uses Key Vault with managed identities."
    }
  }
}
