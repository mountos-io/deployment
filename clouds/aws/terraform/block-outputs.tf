output "blockserv_instances" {
  value = { for k, e in aws_eip.blockserv : k => e.public_ip }
}
