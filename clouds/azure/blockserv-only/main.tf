# Blockserv members on Azure for a hub that runs elsewhere (for example the
# hub on AWS). This root is standalone: it does not need the full-stack module
# in ../terraform, and it creates no appserv, dataserv, database or load balancer.
#
# What it builds:
#   - one resource group with a VNet, a NSG, a Key Vault (RBAC) and one
#     user-assigned identity that reads the Key Vault
#   - optional Azure Blob storage account and container for the block storage
#     entry (create the storage entry on the hub with the account key)
#   - one VM per member with a static public IP and a cache disk, using the same
#     cloud-init template as the full-stack module
#
# Order of work (the hub side is done with the Admin API or CLI):
#   1. terraform apply with block_members = [] (vault, identity, storage first)
#   2. seed-keyvault.sh copies the blockserv secrets from the hub secret store
#   3. on the hub: create the block storage entry on the Blob account, register
#      the copysets, create the volume. Registration mints each member's
#      block_volume_id.
#   4. add the minted ids to block_members and terraform apply again
#   5. on the hub network, allow SRPC 9443 from each member's public IP (AWS hub:
#      external_block_cidrs in clouds/aws/terraform)
#
# Members register with the hub over SRPC on the public path (srpc_addr), so
# the hub address must be reachable from the Azure public IPs.

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

variable "region" {
  type        = string
  description = "Azure region. Use the same geo region as the hub's other services for lower latency."
  default     = "westus2"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.region))
    error_message = "region must be 3 to 30 lower-case letters, digits or hyphens."
  }
}

variable "name" {
  type        = string
  description = "Name root for every resource (resource group, VMs, vault prefix)."
  default     = "mountos-azblock"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,24}$", var.name))
    error_message = "name must be 3 to 25 lower-case letters, digits or hyphens, starting with a letter."
  }
}

variable "resource_prefix" {
  type        = string
  description = "The hub's resource prefix. It becomes VAULT_RESOURCE_PREFIX, so the secrets in the Key Vault are named mountos-<prefix>--<path>. Must match the hub."
  default     = ""

  validation {
    condition     = can(regex("^[a-z0-9-]{0,16}$", var.resource_prefix))
    error_message = "resource_prefix must be at most 16 lower-case letters, digits or hyphens."
  }
}

variable "region_cluster_id" {
  type        = string
  description = "REGION_CLUSTER_ID of the hub region these members belong to."
  default     = ""
}

variable "srpc_addr" {
  type        = string
  description = "host:port of the hub appserv SRPC listener that members register with (port 9443). Must be reachable from the members' public IPs."

  validation {
    condition     = can(regex("^[A-Za-z0-9.-]+:[0-9]{1,5}$", var.srpc_addr))
    error_message = "srpc_addr must be host:port."
  }
}

variable "block_members" {
  type = list(object({
    block_volume_id = string
  }))
  description = "One entry per member, with the block volume UUID minted by copyset registration on the hub. Leave empty for the first apply."
  default     = []
}

variable "client_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the data ports (TCP 9100 and 9101, UDP 9102 and 9103). Use /32 addresses of the clients. SSH is never opened."
  default     = []
}

variable "appserv_cidrs" {
  type        = list(string)
  description = "CIDRs of the hub appserv public addresses, allowed on the blockserv SRPC range 9500-9600. Empty: not opened."
  default     = []
}

variable "vm_size" {
  type        = string
  description = "Member VM size. x86 sizes need image_sku 22_04-lts-gen2, Dpsv5 sizes need 22_04-lts-arm64."
  default     = "Standard_D2s_v5"
}

variable "image_sku" {
  type        = string
  description = "Ubuntu 22.04 image SKU matching vm_size."
  default     = "22_04-lts-gen2"
}

variable "cache_gb" {
  type        = number
  description = "Cache disk size (GiB) per member."
  default     = 128
}

variable "delete_mode" {
  type        = string
  description = "blockserv DELETE_MODE."
  default     = "secured"

  validation {
    condition     = contains(["normal", "secured", "secured-immediate"], var.delete_mode)
    error_message = "delete_mode must be normal, secured, or secured-immediate."
  }
}

variable "mos_version" {
  type        = string
  description = "mountOS package version to install. Empty installs latest. It must match the hub release."
  default     = ""

  validation {
    condition     = var.mos_version == "" || can(regex("^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$", var.mos_version))
    error_message = "mos_version must be empty or a package version made of letters, digits, dot, underscore, plus and hyphen."
  }
}

variable "mos_installer_sha256" {
  type        = string
  description = "SHA-256 of the installer script. Empty skips verification and logs a warning."
  default     = ""
}

variable "admin_ssh_public_key" {
  type        = string
  description = "RSA SSH public key for the mosadmin account (Azure rejects ed25519). Port 22 stays closed, so this is only for console or run-command recovery."

  validation {
    condition     = startswith(var.admin_ssh_public_key, "ssh-rsa ")
    error_message = "admin_ssh_public_key must be an RSA public key (ssh-rsa ...); Azure does not accept other key types."
  }
}

variable "create_blob_storage" {
  type        = bool
  description = "Create the Blob storage account and container that back the block storage entry."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags on every resource."
  default     = {}
}

locals {
  members = { for m in var.block_members : m.block_volume_id => m }
}

data "azurerm_client_config" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "azurerm_resource_group" "main" {
  name     = var.name
  location = var.region
  tags     = var.tags
}

resource "azurerm_virtual_network" "main" {
  name                = var.name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.60.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "main" {
  name                 = "members"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.60.1.0/24"]
}

resource "azurerm_network_security_group" "main" {
  name                = "${var.name}-members"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

# The default NSG rules already allow VNet-internal traffic, which covers peer
# replication on 9101 between members of one copyset.
resource "azurerm_network_security_rule" "client_tcp" {
  count                       = length(var.client_cidrs) > 0 ? 1 : 0
  name                        = "client-tcp"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.main.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["9100", "9101"]
  source_address_prefixes     = var.client_cidrs
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "client_udp" {
  count                       = length(var.client_cidrs) > 0 ? 1 : 0
  name                        = "client-udp"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.main.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_ranges     = ["9102", "9103"]
  source_address_prefixes     = var.client_cidrs
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "appserv_srpc" {
  count                       = length(var.appserv_cidrs) > 0 ? 1 : 0
  name                        = "appserv-srpc"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.main.name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "9500-9600"
  source_address_prefixes     = var.appserv_cidrs
  destination_address_prefix  = "*"
}

# The secret store: blockserv reads its keys, the service verifiers and the
# per-storage credentials here with its managed identity (VAULT_PROVIDER=azure).
resource "azurerm_key_vault" "main" {
  name                       = "mountos-bs-${random_id.suffix.hex}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 30
  tags                       = var.tags
}

resource "azurerm_user_assigned_identity" "blockserv" {
  name                = "${var.name}-blockserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "blockserv_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.blockserv.principal_id
}

# The operator that runs seed-keyvault.sh needs to write secrets.
resource "azurerm_role_assignment" "operator_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_storage_account" "blocks" {
  count                           = var.create_blob_storage ? 1 : 0
  name                            = "mountosbs${random_id.suffix.hex}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "blocks" {
  count                 = var.create_blob_storage ? 1 : 0
  name                  = "mountos-azblock"
  storage_account_name  = azurerm_storage_account.blocks[0].name
  container_access_type = "private"
}

resource "azurerm_public_ip" "member" {
  for_each            = local.members
  name                = "${var.name}-${substr(each.key, 0, 8)}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_managed_disk" "cache" {
  for_each             = local.members
  name                 = "${var.name}-cache-${substr(each.key, 0, 8)}"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.cache_gb
  tags                 = var.tags
}

resource "azurerm_network_interface" "member" {
  for_each            = local.members
  name                = "${var.name}-${substr(each.key, 0, 8)}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.member[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "member" {
  for_each                  = local.members
  network_interface_id      = azurerm_network_interface.member[each.key].id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_linux_virtual_machine" "member" {
  for_each              = local.members
  name                  = "${var.name}-${substr(each.key, 0, 8)}"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = var.vm_size
  admin_username        = "mosadmin"
  network_interface_ids = [azurerm_network_interface.member[each.key].id]
  tags                  = var.tags

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
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = var.image_sku
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.blockserv.id]
  }

  # custom_data is ForceNew: a template or variable change replaces every member
  # in one apply. Use -target to roll members one at a time once they serve.
  custom_data = base64encode(templatefile("${path.module}/../terraform/block-cloud-init.blockserv.sh.tftpl", {
    vault_provider          = "azure"
    vault_addr              = ""
    vault_role_id           = ""
    vault_ca_source         = ""
    key_vault_uri           = azurerm_key_vault.main.vault_uri
    region_vault_ca_secret  = ""
    region_secret_id_secret = ""
    identity_client_id      = azurerm_user_assigned_identity.blockserv.client_id
    region_cluster_id       = var.region_cluster_id
    srpc_addr               = var.srpc_addr
    advertise_addr          = azurerm_public_ip.member[each.key].ip_address
    block_volume_id         = each.key
    delete_mode             = var.delete_mode
    mos_version             = var.mos_version
    mos_installer_sha256    = var.mos_installer_sha256
    resource_prefix         = var.resource_prefix
  }))

  depends_on = [azurerm_role_assignment.blockserv_secrets]
}

resource "azurerm_virtual_machine_data_disk_attachment" "cache" {
  for_each           = local.members
  managed_disk_id    = azurerm_managed_disk.cache[each.key].id
  virtual_machine_id = azurerm_linux_virtual_machine.member[each.key].id
  lun                = 0
  caching            = "ReadWrite"
}
