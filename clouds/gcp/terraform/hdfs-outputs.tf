output "hdfsserv_mig" {
  value = var.hdfs_enable ? google_compute_region_instance_group_manager.hdfsserv[0].name : null
}
