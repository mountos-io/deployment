output "region_vault_addr" {
  value = local.region_vault_endpoint
}

output "dataserv_mig" {
  value = google_compute_region_instance_group_manager.dataserv.name
}
