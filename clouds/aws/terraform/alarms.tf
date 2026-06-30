# Baseline CloudWatch alarms + SNS fan-out. Covers RDS capacity/health, ASG
# in-service count, and load-balancer target health. Intentionally a starting
# floor, not an exhaustive monitoring suite.

resource "aws_sns_topic" "alerts" {
  name = "mountos-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------- admin DB (hub) ----------
resource "aws_cloudwatch_metric_alarm" "admin_rds_storage_low" {
  count               = local.provision_rds ? 1 : 0
  alarm_name          = "mountos-admin-rds-free-storage-low"
  alarm_description   = "Admin RDS free storage below 10% of allocated."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = var.db_allocated_gb * 1024 * 1024 * 1024 * 0.1
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "missing"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.admin[0].identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "admin_rds_cpu_high" {
  count               = local.provision_rds ? 1 : 0
  alarm_name          = "mountos-admin-rds-cpu-high"
  alarm_description   = "Admin RDS CPU above 80%."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "missing"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.admin[0].identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "admin_rds_connections_high" {
  count               = local.provision_rds ? 1 : 0
  alarm_name          = "mountos-admin-rds-connections-high"
  alarm_description   = "Admin RDS connection count sustained high."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 500
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "missing"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.admin[0].identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------- region DB ----------
resource "aws_cloudwatch_metric_alarm" "region_rds_storage_low" {
  count               = local.region_provision_rds ? 1 : 0
  alarm_name          = "mountos-region-rds-free-storage-low"
  alarm_description   = "Region RDS free storage below 10% of allocated."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = var.region_db_allocated_gb * 1024 * 1024 * 1024 * 0.1
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "missing"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.region[0].identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "region_rds_cpu_high" {
  count               = local.region_provision_rds ? 1 : 0
  alarm_name          = "mountos-region-rds-cpu-high"
  alarm_description   = "Region RDS CPU above 80%."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "missing"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.region[0].identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "region_rds_connections_high" {
  count               = local.region_provision_rds ? 1 : 0
  alarm_name          = "mountos-region-rds-connections-high"
  alarm_description   = "Region RDS connection count sustained high."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 500
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "missing"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.region[0].identifier }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------- ASG in-service capacity ----------
resource "aws_cloudwatch_metric_alarm" "appserv_in_service_low" {
  alarm_name          = "mountos-appserv-in-service-low"
  alarm_description   = "appserv in-service instances below desired."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = var.appserv_count
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "breaching"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.appserv.name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dataserv_in_service_low" {
  alarm_name          = "mountos-dataserv-in-service-low"
  alarm_description   = "dataserv in-service instances below desired."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = var.dataserv_count
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "breaching"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.dataserv.name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------- load-balancer target health ----------
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "mountos-alb-unhealthy-hosts"
  alarm_description   = "ALB has unhealthy appserv HTTP targets."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.appserv.arn_suffix
    TargetGroup  = aws_lb_target_group.appserv_http.arn_suffix
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "nlb_unhealthy_hosts" {
  alarm_name          = "mountos-nlb-unhealthy-hosts"
  alarm_description   = "NLB has unhealthy appserv SRPC targets."
  namespace           = "AWS/NetworkELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.appserv_srpc.arn_suffix
    TargetGroup  = aws_lb_target_group.appserv_srpc.arn_suffix
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
}
