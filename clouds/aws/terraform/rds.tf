# Admin DB (mountos_admin). Provisioned only when admin_db_mode = provision-rds.
resource "aws_db_subnet_group" "admin" {
  count      = local.provision_rds ? 1 : 0
  name       = "mountos-admin"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "mountos-admin" }
}

resource "aws_security_group" "rds" {
  count       = local.provision_rds ? 1 : 0
  name        = "mountos-rds"
  description = "admin RDS: postgres from appserv only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "mountos-rds" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_appserv" {
  count                        = local.provision_rds ? 1 : 0
  security_group_id            = aws_security_group.rds[0].id
  referenced_security_group_id = aws_security_group.appserv.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "postgres from appserv"
}

resource "aws_vpc_security_group_egress_rule" "rds_all" {
  count             = local.provision_rds ? 1 : 0
  security_group_id = aws_security_group.rds[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_db_instance" "admin" {
  count                      = local.provision_rds ? 1 : 0
  identifier                 = "mountos-admin"
  engine                     = "postgres"
  engine_version             = var.admin_db_provider_version
  instance_class             = var.db_instance_class
  allocated_storage          = var.db_allocated_gb
  db_name                    = "mountos_admin"
  username                   = var.db_username
  password                   = var.db_password
  db_subnet_group_name       = aws_db_subnet_group.admin[0].name
  vpc_security_group_ids     = [aws_security_group.rds[0].id]
  storage_encrypted          = true
  skip_final_snapshot        = var.mode != "production"
  final_snapshot_identifier  = "mountos-admin-final"
  deletion_protection        = var.mode == "production"
  backup_retention_period    = 14
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = false
  max_allocated_storage      = var.db_allocated_gb * 4
  multi_az                   = var.mode == "production"
  tags                       = { Name = "mountos-admin" }

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.db_password != ""
      error_message = "db_password must be set (provision-rds mode)."
    }
  }
}
