# Region network placement. shared (default): region resources live in the
# hub's VNet. dedicated: the region gets its own VNet in the SAME
# subscription/resource group + Azure region, connected via VNet Peering.
# Like GCP (and unlike AWS), Azure VNet peering auto-enables connectivity
# between the peered address spaces once both sides are up — no manual route
# table entries needed. Cross-VNet firewall rules still need explicit
# CIDR-based source_address_prefixes (Application Security Groups don't match
# across the peering boundary — same reasoning as AWS/GCP dedicated-mode).
#
# NOT covered here: true cross-subscription regions (needs peering across
# subscriptions, explicit consent) or a different Azure region (needs region-
# scoped subnet CIDR planning across two regions). Both are separate changes.
variable "region_vpc_mode" {
  type        = string
  description = "Region network placement: shared (default; region resources live in the hub VNet) | dedicated (region gets its own VNet, peered to the hub VNet)."
  default     = "shared"
  validation {
    condition     = contains(["shared", "dedicated"], var.region_vpc_mode)
    error_message = "region_vpc_mode must be shared or dedicated."
  }
}

variable "region_vnet_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "region_vnet_cidr_public" {
  type    = string
  default = "10.1.0.0/24"
}

variable "region_vnet_cidr_private" {
  type    = string
  default = "10.1.10.0/24"
}

locals {
  region_dedicated_vnet = var.region_vpc_mode == "dedicated"

  region_network       = local.region_dedicated_vnet ? azurerm_virtual_network.region[0].id : azurerm_virtual_network.main.id
  region_public_subnet = local.region_dedicated_vnet ? azurerm_subnet.region_public[0] : azurerm_subnet.public
  # NSGs are resource-group-scoped, not VNet-bound — the same NSG applies
  # regardless of region_vpc_mode, wired per-NIC on each compute resource.
  region_nsg_id = azurerm_network_security_group.region.id
}

resource "azurerm_virtual_network" "region" {
  count               = local.region_dedicated_vnet ? 1 : 0
  name                = "${local.name_root}-region"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.region_vnet_cidr]
}

resource "azurerm_subnet" "region_public" {
  count                = local.region_dedicated_vnet ? 1 : 0
  name                 = "${local.name_root}-region-public"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.region[0].name
  address_prefixes     = [var.region_vnet_cidr_public]
}

resource "azurerm_subnet" "region_private" {
  count                = local.region_dedicated_vnet ? 1 : 0
  name                 = "${local.name_root}-region-private"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.region[0].name
  address_prefixes     = [var.region_vnet_cidr_private]
}

resource "azurerm_public_ip" "region_nat" {
  count               = local.region_dedicated_vnet ? 1 : 0
  name                = "${local.name_root}-region-nat"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
}

resource "azurerm_nat_gateway" "region_nat" {
  count               = local.region_dedicated_vnet ? 1 : 0
  name                = "${local.name_root}-region-nat"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "region_nat" {
  count                = local.region_dedicated_vnet ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.region_nat[0].id
  public_ip_address_id = azurerm_public_ip.region_nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "region_private" {
  count          = local.region_dedicated_vnet ? 1 : 0
  subnet_id      = azurerm_subnet.region_private[0].id
  nat_gateway_id = azurerm_nat_gateway.region_nat[0].id
}

# Both directions required — same as GCP, unlike AWS's single peering resource.
resource "azurerm_virtual_network_peering" "hub_to_region" {
  count                        = local.region_dedicated_vnet ? 1 : 0
  name                         = "${local.name_root}-hub-to-region"
  resource_group_name          = azurerm_resource_group.main.name
  virtual_network_name         = azurerm_virtual_network.main.name
  remote_virtual_network_id    = azurerm_virtual_network.region[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_virtual_network_peering" "region_to_hub" {
  count                        = local.region_dedicated_vnet ? 1 : 0
  name                         = "${local.name_root}-region-to-hub"
  resource_group_name          = azurerm_resource_group.main.name
  virtual_network_name         = azurerm_virtual_network.region[0].name
  remote_virtual_network_id    = azurerm_virtual_network.main.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

output "region_network_id" {
  value = local.region_dedicated_vnet ? azurerm_virtual_network.region[0].id : null
}
