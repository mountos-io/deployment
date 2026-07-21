# ---------- Application Gateway (client-facing hub, HTTPS re-encrypt) ----------
# App Gateway REQUIRES its own dedicated subnet (Azure constraint — cannot
# share a subnet with VMs/VMSS).
variable "appgw_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

resource "azurerm_subnet" "appgw" {
  name                 = "${local.name_root}-appgw"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.appgw_subnet_cidr]
}

# App Gateway's own NSG. REQUIRED rules for a v2 SKU to function at all
# (control-plane health/management traffic and LB health probes) plus the
# actual client-facing restriction — without this NSG, the appgw subnet had
# NO inbound restriction whatsoever (client_cidr was never actually applied
# to the internet-facing hub entrypoint, unlike AWS's ALB security group).
resource "azurerm_network_security_group" "appgw" {
  name                = "${local.name_root}-appgw"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_network_security_rule" "appgw_client_https" {
  name                        = "appgw-client-https"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.appgw.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.client_cidr
  destination_address_prefix  = "*"
}

# Mandatory for Standard_v2: Azure's control plane manages/health-checks the
# gateway over this range. Without it the gateway silently fails to operate.
resource "azurerm_network_security_rule" "appgw_gateway_manager" {
  name                        = "appgw-gateway-manager"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.appgw.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "GatewayManager"
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "appgw_azure_lb" {
  name                        = "appgw-azure-lb"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.appgw.name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

resource "azurerm_public_ip" "appgw" {
  name                = "${local.name_root}-appgw"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.zones
}

# Identity the App Gateway uses to pull the HTTPS cert from Key Vault. The
# OPERATOR must grant this identity "Key Vault Certificates User" (or
# Secrets User) on whichever Key Vault holds hub_certificate_secret_id —
# Terraform cannot infer that vault's scope reliably from a bare secret id.
resource "azurerm_user_assigned_identity" "appgw" {
  name                = "${local.name_root}-appgw"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_application_gateway" "hub" {
  name                = "${local.name_root}-appserv"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  autoscale_configuration {
    min_capacity = 2
    max_capacity = 10
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw.id]
  }

  gateway_ip_configuration {
    name      = "appgw-ip"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_ip_configuration {
    name                 = "frontend"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "https"
    port = 443
  }

  ssl_certificate {
    name                = "hub"
    key_vault_secret_id = var.hub_certificate_secret_id
  }

  backend_address_pool {
    name = "appserv"
  }

  # Re-encrypt: App Gateway terminates client TLS, re-encrypts to appserv:8443 (self-signed).
  backend_http_settings {
    name                  = "appserv-https"
    cookie_based_affinity = "Disabled"
    port                  = 8443
    protocol              = "Https"
    request_timeout       = 30
    probe_name            = "appserv-health"
  }

  probe {
    name                                      = "appserv-health"
    protocol                                  = "Https"
    path                                      = "/api/v1/me"
    interval                                  = 10
    timeout                                   = 5
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true
    match {
      status_code = ["200-499"]
    }
  }

  http_listener {
    name                           = "https"
    frontend_ip_configuration_name = "frontend"
    frontend_port_name             = "https"
    protocol                       = "Https"
    ssl_certificate_name           = "hub"
  }

  request_routing_rule {
    name                       = "hub"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = "https"
    backend_address_pool_name  = "appserv"
    backend_http_settings_name = "appserv-https"
  }

  lifecycle {
    precondition {
      condition     = var.hub_certificate_secret_id != ""
      error_message = "Set hub_certificate_secret_id — Azure has no zero-touch managed-cert primitive; bring your own certificate via Key Vault."
    }
  }
}

output "appgw_ip" {
  value = azurerm_public_ip.appgw.ip_address
}

# ---------- internal Standard LB (SRPC :9443, TCP passthrough) ----------
# Internal: the SRPC control plane must not be internet-facing. Region services
# reach it from inside the VNet.
resource "azurerm_lb" "appserv_srpc" {
  name                = "${local.name_root}-appserv-srpc"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(var.vnet_cidr_private, 10)
  }
}

resource "azurerm_lb_backend_address_pool" "appserv_srpc" {
  name            = "appserv"
  loadbalancer_id = azurerm_lb.appserv_srpc.id
}

# Probe traffic originates from 168.63.129.16 (service tag AzureLoadBalancer),
# admitted by every NSG's default AllowAzureLoadBalancerInBound rule — the hub
# NSG defines no custom Deny that could override it, so no explicit allow is
# needed (unlike AWS, where NLB health checks needed their own SG rule).
resource "azurerm_lb_probe" "appserv_health" {
  name                = "appserv-srpc"
  loadbalancer_id     = azurerm_lb.appserv_srpc.id
  protocol            = "Tcp"
  port                = 9443
  interval_in_seconds = 10
  number_of_probes    = 3
}

resource "azurerm_lb_rule" "appserv_srpc" {
  name                           = "srpc"
  loadbalancer_id                = azurerm_lb.appserv_srpc.id
  protocol                       = "Tcp"
  frontend_port                  = 9443
  backend_port                   = 9443
  frontend_ip_configuration_name = "internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.appserv_srpc.id]
  probe_id                       = azurerm_lb_probe.appserv_health.id
}

output "srpc_lb_ip" {
  value = azurerm_lb.appserv_srpc.frontend_ip_configuration[0].private_ip_address
}
