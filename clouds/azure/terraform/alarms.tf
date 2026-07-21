# Baseline Azure Monitor metric alerts + action group. Covers Postgres
# capacity/health and VMSS unhealthy-instance count. Intentionally a starting
# floor, not an exhaustive monitoring suite (mirrors alarms.tf on AWS/GCP).

resource "azurerm_monitor_action_group" "alerts" {
  count               = var.alarm_email != "" ? 1 : 0
  name                = "${local.name_root}-alerts"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "mosalerts"

  email_receiver {
    name          = "operator"
    email_address = var.alarm_email
  }
}

resource "azurerm_monitor_metric_alert" "admin_db_storage_low" {
  count               = local.provision_pg ? 1 : 0
  name                = "${local.name_root}-admin-db-storage-low"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.admin[0].id]
  description         = "Admin Postgres free storage below 10%."

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 90
  }

  dynamic "action" {
    for_each = var.alarm_email != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.alerts[0].id
    }
  }
}

resource "azurerm_monitor_metric_alert" "admin_db_cpu_high" {
  count               = local.provision_pg ? 1 : 0
  name                = "${local.name_root}-admin-db-cpu-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.admin[0].id]
  description         = "Admin Postgres CPU above 80%."

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  dynamic "action" {
    for_each = var.alarm_email != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.alerts[0].id
    }
  }
}

resource "azurerm_monitor_metric_alert" "admin_db_connections_high" {
  count               = local.provision_pg ? 1 : 0
  name                = "${local.name_root}-admin-db-connections-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.admin[0].id]
  description         = "Admin Postgres connection count sustained high."

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "active_connections"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 500
  }

  dynamic "action" {
    for_each = var.alarm_email != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.alerts[0].id
    }
  }
}

resource "azurerm_monitor_metric_alert" "region_db_storage_low" {
  count               = local.region_provision_pg ? 1 : 0
  name                = "${local.name_root}-region-db-storage-low"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.region[0].id]
  description         = "Region Postgres free storage below 10%."

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 90
  }

  dynamic "action" {
    for_each = var.alarm_email != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.alerts[0].id
    }
  }
}

resource "azurerm_monitor_metric_alert" "region_db_cpu_high" {
  count               = local.region_provision_pg ? 1 : 0
  name                = "${local.name_root}-region-db-cpu-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.region[0].id]
  description         = "Region Postgres CPU above 80%."

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  dynamic "action" {
    for_each = var.alarm_email != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.alerts[0].id
    }
  }
}

resource "azurerm_monitor_metric_alert" "region_db_connections_high" {
  count               = local.region_provision_pg ? 1 : 0
  name                = "${local.name_root}-region-db-connections-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_postgresql_flexible_server.region[0].id]
  description         = "Region Postgres connection count sustained high."

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "active_connections"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 500
  }

  dynamic "action" {
    for_each = var.alarm_email != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.alerts[0].id
    }
  }
}

# Alerts on the App Gateway's view of backend health (mirrors AWS's
# alb_unhealthy_hosts / GCP's instance-group current_size — the load
# balancer's own target-health signal, not a proxy metric on the fleet itself).
resource "azurerm_monitor_metric_alert" "appgw_unhealthy_hosts" {
  name                = "${local.name_root}-appgw-unhealthy-hosts"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_application_gateway.hub.id]
  description         = "App Gateway has unhealthy appserv backend hosts."

  criteria {
    metric_namespace = "Microsoft.Network/applicationGateways"
    metric_name      = "UnhealthyHostCount"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 0
  }

  dynamic "action" {
    for_each = var.alarm_email != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.alerts[0].id
    }
  }
}
