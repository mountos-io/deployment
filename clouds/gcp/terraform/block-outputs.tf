output "blockserv_instances" {
  value = { for k, a in google_compute_address.blockserv : k => a.address }
}
