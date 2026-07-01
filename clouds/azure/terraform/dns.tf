# Public DNS, only when an existing Azure DNS zone is supplied.
data "azurerm_dns_zone" "hub" {
  count               = var.dns_zone_name != "" ? 1 : 0
  name                = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group
}

resource "azurerm_dns_a_record" "hub" {
  count = var.dns_zone_name != "" ? 1 : 0
  # Apex domain (hub_domain == dns_zone_name) needs Azure's "@" sentinel —
  # trimsuffix(hub_domain, ".zone") never matches (no leading dot to strip),
  # so it silently returns hub_domain unchanged, creating a wrong record
  # (e.g. "acme.com" inside zone "acme.com" resolves as acme.com.acme.com,
  # not acme.com) instead of failing loudly.
  name                = var.hub_domain == var.dns_zone_name ? "@" : trimsuffix(var.hub_domain, ".${var.dns_zone_name}")
  zone_name           = data.azurerm_dns_zone.hub[0].name
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 60
  records             = [azurerm_public_ip.appgw.ip_address]
}

# Publishes the internal SRPC LB address for operator/discovery convenience
# (mirrors AWS's route53.tf). Region cloud-init templates use the LB IP
# output directly, not this record - it resolves publicly but only routes
# from networks with a path to the internal LB (VNet/peered).
resource "azurerm_dns_a_record" "srpc" {
  count               = var.dns_zone_name != "" ? 1 : 0
  name                = var.hub_domain == var.dns_zone_name ? "srpc" : "srpc.${trimsuffix(var.hub_domain, ".${var.dns_zone_name}")}"
  zone_name           = data.azurerm_dns_zone.hub[0].name
  resource_group_name = var.dns_zone_resource_group
  ttl                 = 60
  records             = [azurerm_lb.appserv_srpc.frontend_ip_configuration[0].private_ip_address]
}
