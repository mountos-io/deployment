output "hdfsserv_instances" {
  value = var.hdfs_enable ? aws_autoscaling_group.hdfsserv[0].name : null
}
