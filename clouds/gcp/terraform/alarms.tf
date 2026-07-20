# Baseline Cloud Monitoring alert policies + notification channel. Covers Cloud
# SQL capacity/health/connections (admin + region). Intentionally a starting
# floor, not an exhaustive monitoring suite (mirrors alarms.tf on AWS).
#
# NOT covered here (open gap, not silently claimed as done): a MIG/backend-
# service health alert for appserv/dataserv. GCP's
# instance-group/backend-service Monitoring resource types and label schemas
# (self-link vs bare name, gce_instance_group vs gce_instance_group_manager,
# the exact metric name) could not be confirmed without live API access — an
# earlier attempt here used a fabricated metric name and an unverified label
# shape, so it was REMOVED rather than left in place silently never firing
# (a misleading alert is worse than no alert — same call made for an
# analogous Azure Monitor gap in clouds/azure/terraform/alarms.tf). Fill this
# in during a runtime-validated session against a real project.

resource "google_monitoring_notification_channel" "email" {
  count        = var.alarm_email != "" ? 1 : 0
  display_name = "mountos-alerts"
  type         = "email"
  labels = {
    email_address = var.alarm_email
  }
}

resource "google_monitoring_alert_policy" "admin_sql_storage_low" {
  count        = local.provision_sql ? 1 : 0
  display_name = "mountos-admin-sql-free-storage-low"
  combiner     = "OR"
  conditions {
    display_name = "Admin Cloud SQL free storage below 10%"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.project_id}:${google_sql_database_instance.admin[0].name}\" AND metric.type=\"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.9
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  notification_channels = var.alarm_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

resource "google_monitoring_alert_policy" "admin_sql_cpu_high" {
  count        = local.provision_sql ? 1 : 0
  display_name = "mountos-admin-sql-cpu-high"
  combiner     = "OR"
  conditions {
    display_name = "Admin Cloud SQL CPU above 80%"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.project_id}:${google_sql_database_instance.admin[0].name}\" AND metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  notification_channels = var.alarm_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

resource "google_monitoring_alert_policy" "admin_sql_connections_high" {
  count        = local.provision_sql ? 1 : 0
  display_name = "mountos-admin-sql-connections-high"
  combiner     = "OR"
  conditions {
    display_name = "Admin Cloud SQL connection count sustained high"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.project_id}:${google_sql_database_instance.admin[0].name}\" AND metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\""
      comparison      = "COMPARISON_GT"
      threshold_value = 500
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  notification_channels = var.alarm_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

resource "google_monitoring_alert_policy" "region_sql_storage_low" {
  count        = local.region_provision_sql ? 1 : 0
  display_name = "mountos-region-sql-free-storage-low"
  combiner     = "OR"
  conditions {
    display_name = "Region Cloud SQL free storage below 10%"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.project_id}:${google_sql_database_instance.region[0].name}\" AND metric.type=\"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.9
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  notification_channels = var.alarm_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

resource "google_monitoring_alert_policy" "region_sql_cpu_high" {
  count        = local.region_provision_sql ? 1 : 0
  display_name = "mountos-region-sql-cpu-high"
  combiner     = "OR"
  conditions {
    display_name = "Region Cloud SQL CPU above 80%"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.project_id}:${google_sql_database_instance.region[0].name}\" AND metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  notification_channels = var.alarm_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}

resource "google_monitoring_alert_policy" "region_sql_connections_high" {
  count        = local.region_provision_sql ? 1 : 0
  display_name = "mountos-region-sql-connections-high"
  combiner     = "OR"
  conditions {
    display_name = "Region Cloud SQL connection count sustained high"
    condition_threshold {
      filter          = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.project_id}:${google_sql_database_instance.region[0].name}\" AND metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\""
      comparison      = "COMPARISON_GT"
      threshold_value = 500
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  notification_channels = var.alarm_email != "" ? [google_monitoring_notification_channel.email[0].id] : []
}
