# Admin DB (mountos_admin). Provisioned only when admin_db_mode = provision-rds.
resource "aws_db_subnet_group" "admin" {
  count      = local.provision_rds ? 1 : 0
  name       = "${local.name_root}-admin"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${local.name_root}-admin" }
}

resource "aws_security_group" "rds" {
  count       = local.provision_rds ? 1 : 0
  name        = "${local.name_root}-rds"
  description = "admin RDS: postgres from appserv only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name_root}-rds" }
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

# Fresh per-apply-lifecycle suffix (not timestamp(), which would diff every
# plan) so a final snapshot from a prior destroy doesn't collide with the
# identifier a later destroy tries to reuse in the same account/region.
resource "random_id" "admin_final_snapshot" {
  count       = local.provision_rds ? 1 : 0
  byte_length = 4
}

# Server-side TLS enforcement: bootstrap DSN construction already sets
# sslmode=require, but that's client-side only - force it here too so a
# future client that omits the flag can't connect in plaintext.
resource "aws_db_parameter_group" "admin" {
  count  = local.provision_rds ? 1 : 0
  name   = "${local.name_root}-admin"
  family = "postgres${var.admin_db_provider_version}"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "admin" {
  count                      = local.provision_rds ? 1 : 0
  identifier                 = "${local.name_root}-admin"
  engine                     = "postgres"
  engine_version             = var.admin_db_provider_version
  instance_class             = var.db_instance_class
  allocated_storage          = var.db_allocated_gb
  db_name                    = "mountos_admin"
  username                   = var.db_username
  db_subnet_group_name       = aws_db_subnet_group.admin[0].name
  vpc_security_group_ids     = [aws_security_group.rds[0].id]
  parameter_group_name       = aws_db_parameter_group.admin[0].name
  storage_encrypted          = true
  skip_final_snapshot        = var.mode != "production"
  final_snapshot_identifier  = "${local.name_root}-admin-final-${random_id.admin_final_snapshot[0].hex}"
  deletion_protection        = var.mode == "production"
  backup_retention_period    = 14
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = false
  max_allocated_storage      = var.db_allocated_gb * 4
  multi_az                   = var.mode == "production"
  tags                       = { Name = "${local.name_root}-admin" }

  # AWS generates and rotates the master password in Secrets Manager; it is
  # never a Terraform value, so it never lands in tfstate or user_data. The
  # secret ARN is read at seed time (see bootstrap/seed-vault.sh) by the
  # operator, not by instances — appserv gets its DSN from Vault, never from
  # Secrets Manager directly.
  manage_master_user_password = true

  # No prevent_destroy: deletion_protection (above) is the real safety net and
  # is correctly mode-gated to production only. prevent_destroy is a Terraform
  # meta-argument that can't take a variable, so it would block dev/staging
  # teardown too if set unconditionally.
}
