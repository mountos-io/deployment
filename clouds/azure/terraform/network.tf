# Azure subnets, like GCP, span every zone in the region — no per-AZ subnet
# model like AWS. "public"/"private" is a per-NIC property (whether a Public
# IP is attached), same as GCP; kept as two subnets anyway for NAT Gateway
# scoping + AWS-module legibility.

variable "vnet_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "vnet_cidr_public" {
  type    = string
  default = "10.0.0.0/24"
}

variable "vnet_cidr_private" {
  type    = string
  default = "10.0.10.0/24"
}

# Zones this fleet spreads across (HA). Azure picks the zone per-VM/VMSS
# instance, not per-subnet — same model as GCP.
variable "zones" {
  type        = list(string)
  description = "Availability zones within var.region to spread instances across (HA)."
  default     = ["1", "2", "3"]
}

resource "azurerm_virtual_network" "main" {
  name                = local.name_root
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.vnet_cidr]
}

resource "azurerm_subnet" "public" {
  name                 = "${local.name_root}-public"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.vnet_cidr_public]
}

resource "azurerm_subnet" "private" {
  name                 = "${local.name_root}-private"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.vnet_cidr_private]
}

# NAT Gateway for the private subnet's egress (n.sh installer, package fetches,
# Vault/Key Vault calls out). Public-subnet instances use their own public IP.
resource "azurerm_public_ip" "nat" {
  name                = "${local.name_root}-nat"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
}

resource "azurerm_nat_gateway" "nat" {
  name                = "${local.name_root}-nat"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "nat" {
  nat_gateway_id       = azurerm_nat_gateway.nat.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "private" {
  subnet_id      = azurerm_subnet.private.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "public_subnet_id" {
  value = azurerm_subnet.public.id
}

output "private_subnet_id" {
  value = azurerm_subnet.private.id
}
