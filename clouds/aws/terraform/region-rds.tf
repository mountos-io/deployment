# Region DB (mountos_data). Provisioned only when region_db_mode = provision-rds.
# Separate from the hub admin DB per mountOS topology.
resource "aws_db_subnet_group" "region" {
  count      = local.region_provision_rds ? 1 : 0
  name       = "mountos-region"
  subnet_ids = local.region_subnets[*].id
  tags       = { Name = "mountos-region" }
}

resource "aws_security_group" "region_rds" {
  count       = local.region_provision_rds ? 1 : 0
  name        = "mountos-region-rds"
  description = "region RDS: postgres from dataserv only"
  vpc_id      = local.region_vpc_id
  tags        = { Name = "mountos-region-rds" }
}

resource "aws_vpc_security_group_ingress_rule" "region_rds_from_dataserv" {
  count                        = local.region_provision_rds ? 1 : 0
  security_group_id            = aws_security_group.region_rds[0].id
  referenced_security_group_id = aws_security_group.dataserv.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "postgres from dataserv"
}

resource "aws_vpc_security_group_egress_rule" "region_rds_all" {
  count             = local.region_provision_rds ? 1 : 0
  security_group_id = aws_security_group.region_rds[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_db_instance" "region" {
  count                      = local.region_provision_rds ? 1 : 0
  identifier                 = "mountos-region"
  engine                     = "postgres"
  engine_version             = var.region_db_provider_version
  instance_class             = var.region_db_instance_class
  allocated_storage          = var.region_db_allocated_gb
  db_name                    = "mountos_data"
  username                   = var.region_db_username
  db_subnet_group_name       = aws_db_subnet_group.region[0].name
  vpc_security_group_ids     = [aws_security_group.region_rds[0].id]
  storage_encrypted          = true
  skip_final_snapshot        = var.mode != "production"
  final_snapshot_identifier  = "mountos-region-final"
  deletion_protection        = var.mode == "production"
  backup_retention_period    = 14
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = false
  max_allocated_storage      = var.region_db_allocated_gb * 4
  multi_az                   = var.mode == "production"
  tags                       = { Name = "mountos-region" }

  # AWS generates and rotates the master password in Secrets Manager; it is
  # never a Terraform value, so it never lands in tfstate or user_data. The
  # secret ARN is read at seed time (see bootstrap/region-seed.sh) by the
  # operator, not by instances — dataserv gets its DSN from Vault, never from
  # Secrets Manager directly.
  manage_master_user_password = true

  lifecycle {
    prevent_destroy = true
  }
}
