output "s3gatewayserv_mig" {
  value = var.s3gateway_enable ? google_compute_region_instance_group_manager.s3gatewayserv[0].name : null
}
