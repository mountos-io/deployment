output "blockserv_instances" {
  value = { for k, i in aws_instance.blockserv : k => i.private_ip }
}
