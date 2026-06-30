output "region_vault_addr" {
  value = local.region_vault_endpoint
}

output "region_db_url" {
  value     = local.region_dsn
  sensitive = true
}

output "dataserv_asg" {
  value = aws_autoscaling_group.dataserv.name
}
