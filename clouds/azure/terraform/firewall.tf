# Azure Application Security Groups (ASGs — NOT to be confused with an AWS
# Auto Scaling Group) let NSG rules reference source/destination ASGs, closely
# mirroring AWS's SG-to-SG references (closer than GCP's network-wide tag
# model). Each mountOS tier gets an ASG; NICs join the ASG via
# azurerm_network_interface_application_security_group_association.
#
# LIKE GCP (and unlike AWS same-VPC SGs): ASG-based rules do NOT cross a VNet
# peering boundary — cross-VNet traffic (hub<->region, dedicated mode) needs
# CIDR-based rules instead, same reasoning as the AWS/GCP dedicated-mode fixes.
#
# IMPORTANT: blockserv otherwise picks a DYNAMIC SRPC port (ephemeral :0),
# which cannot be firewalled. Deploy MUST set PORT_RANGE on that service to
# exactly the range below so appserv -> service SRPC is allowed.

variable "client_cidr" {
  description = "CIDR allowed to reach client-facing ports (appserv 443, dataserv 6464, blockserv 9100) (required — do not use 0.0.0.0/0 in production)."
  type        = string
}

locals {
  srpc_range_from = 9500
  srpc_range_to   = 9600 # set PORT_RANGE=9500-9600 on blockserv
}

resource "azurerm_application_security_group" "appserv" {
  name                = "${local.name_root}-appserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_application_security_group" "dataserv" {
  name                = "${local.name_root}-dataserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_application_security_group" "gcserv" {
  name                = "${local.name_root}-gcserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_application_security_group" "blockserv" {
  name                = "${local.name_root}-blockserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# ---------- hub NSG (appserv) ----------
resource "azurerm_network_security_group" "hub" {
  name                = "${local.name_root}-hub"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_network_security_rule" "appserv_https_from_gateway" {
  name                                       = "appserv-https-from-appgw"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.hub.name
  priority                                   = 100
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8443"
  source_address_prefix                      = var.appgw_subnet_cidr # App Gateway subnet re-encrypts to appserv
  destination_application_security_group_ids = [azurerm_application_security_group.appserv.id]
}

resource "azurerm_network_security_rule" "appserv_srpc_from_dataserv" {
  count                                      = local.region_dedicated_vnet ? 0 : 1
  name                                       = "appserv-srpc-from-dataserv"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.hub.name
  priority                                   = 110
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "9443"
  source_application_security_group_ids      = [azurerm_application_security_group.dataserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.appserv.id]
}

resource "azurerm_network_security_rule" "appserv_srpc_from_gcserv" {
  count                                      = local.region_dedicated_vnet ? 0 : 1
  name                                       = "appserv-srpc-from-gcserv"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.hub.name
  priority                                   = 111
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "9443"
  source_application_security_group_ids      = [azurerm_application_security_group.gcserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.appserv.id]
}

resource "azurerm_network_security_rule" "appserv_srpc_from_blockserv" {
  count                                      = local.region_dedicated_vnet ? 0 : 1
  name                                       = "appserv-srpc-from-blockserv"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.hub.name
  priority                                   = 112
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "9443"
  source_application_security_group_ids      = [azurerm_application_security_group.blockserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.appserv.id]
}

# dedicated mode: one CIDR-based rule covers all region services (same
# port), since ASGs don't match across the peering boundary.
resource "azurerm_network_security_rule" "appserv_srpc_from_region_cidr" {
  count                                      = local.region_dedicated_vnet ? 1 : 0
  name                                       = "appserv-srpc-from-region-cidr"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.hub.name
  priority                                   = 114
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "9443"
  source_address_prefixes                    = [var.region_vnet_cidr_public, var.region_vnet_cidr_private]
  destination_application_security_group_ids = [azurerm_application_security_group.appserv.id]
}

# NSGs are wired per-NIC on each compute resource (compute.tf, region-compute.tf,
# block-compute.tf, ...), NOT via subnet association: in shared mode, region
# services live in the SAME subnets as appserv, and Azure allows only ONE NSG
# per subnet — per-NIC association is what lets different tiers share a subnet
# while each getting its own rule set.

# ---------- region NSG (dataserv/gcserv/blockserv) ----------
resource "azurerm_network_security_group" "region" {
  name                = "${local.name_root}-region"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_network_security_rule" "dataserv_client" {
  name                                       = "dataserv-client"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 100
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "6464"
  source_address_prefix                      = var.client_cidr
  destination_application_security_group_ids = [azurerm_application_security_group.dataserv.id]
}

resource "azurerm_network_security_rule" "dataserv_raft_self" {
  name                                       = "dataserv-raft-self"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 102
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "6465"
  source_application_security_group_ids      = [azurerm_application_security_group.dataserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.dataserv.id]
}

resource "azurerm_network_security_rule" "dataserv_srpc_from_appserv" {
  count                                      = local.region_dedicated_vnet ? 0 : 1
  name                                       = "dataserv-srpc-from-appserv"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 103
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "6466"
  source_application_security_group_ids      = [azurerm_application_security_group.appserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.dataserv.id]
}

resource "azurerm_network_security_rule" "dataserv_srpc_from_appserv_cidr" {
  count                                      = local.region_dedicated_vnet ? 1 : 0
  name                                       = "dataserv-srpc-from-appserv-cidr"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 104
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "6466"
  source_address_prefixes                    = [var.vnet_cidr_public, var.vnet_cidr_private]
  destination_application_security_group_ids = [azurerm_application_security_group.dataserv.id]
}

resource "azurerm_network_security_rule" "gcserv_srpc_from_appserv" {
  count                                      = local.region_dedicated_vnet ? 0 : 1
  name                                       = "gcserv-srpc-from-appserv"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 105
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8081"
  source_application_security_group_ids      = [azurerm_application_security_group.appserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.gcserv.id]
}

resource "azurerm_network_security_rule" "gcserv_srpc_from_appserv_cidr" {
  count                                      = local.region_dedicated_vnet ? 1 : 0
  name                                       = "gcserv-srpc-from-appserv-cidr"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 106
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "8081"
  source_address_prefixes                    = [var.vnet_cidr_public, var.vnet_cidr_private]
  destination_application_security_group_ids = [azurerm_application_security_group.gcserv.id]
}

resource "azurerm_network_security_rule" "blockserv_client" {
  name                                       = "blockserv-client"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 107
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "9100"
  source_address_prefix                      = var.client_cidr
  destination_application_security_group_ids = [azurerm_application_security_group.blockserv.id]
}

resource "azurerm_network_security_rule" "blockserv_peer_self" {
  name                                       = "blockserv-peer-self"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 108
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "9101"
  source_application_security_group_ids      = [azurerm_application_security_group.blockserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.blockserv.id]
}

resource "azurerm_network_security_rule" "blockserv_srpc_from_appserv" {
  count                                      = local.region_dedicated_vnet ? 0 : 1
  name                                       = "blockserv-srpc-from-appserv"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 109
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "${local.srpc_range_from}-${local.srpc_range_to}"
  source_application_security_group_ids      = [azurerm_application_security_group.appserv.id]
  destination_application_security_group_ids = [azurerm_application_security_group.blockserv.id]
}

resource "azurerm_network_security_rule" "blockserv_srpc_from_appserv_cidr" {
  count                                      = local.region_dedicated_vnet ? 1 : 0
  name                                       = "blockserv-srpc-from-appserv-cidr"
  resource_group_name                        = azurerm_resource_group.main.name
  network_security_group_name                = azurerm_network_security_group.region.name
  priority                                   = 115
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "${local.srpc_range_from}-${local.srpc_range_to}"
  source_address_prefixes                    = [var.vnet_cidr_public, var.vnet_cidr_private]
  destination_application_security_group_ids = [azurerm_application_security_group.blockserv.id]
}

# NSGs are resource-group-scoped, not VNet-bound — the single azurerm_network_security_group.region
# above is reused for the region tier regardless of region_vpc_mode, wired per-NIC (see above note).
