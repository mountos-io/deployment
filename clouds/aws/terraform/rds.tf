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

# Opt-in only (var.share_admin_rds_with_region): lets region_db_mode = byo point
# REGION_DB_URL at this SAME instance (a different database on it, e.g.
# mountos_data alongside mountos_admin) instead of provisioning a second RDS
# instance. Off by default — region_db_mode = byo normally means an operator's
# own external DB with its own network ACLs, which this package has no reason
# to open the admin RDS's security group for.
resource "aws_vpc_security_group_ingress_rule" "rds_from_dataserv_shared" {
  count                        = local.provision_rds && var.share_admin_rds_with_region ? 1 : 0
  security_group_id            = aws_security_group.rds[0].id
  referenced_security_group_id = aws_security_group.dataserv.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "postgres from dataserv (shared single-RDS mode)"
}

# admin-client's optional native-login extension (MOUNTOS_PORTAL_DATABASE_URL) talks
# to this SAME instance directly, a different database (mountos_portal) alongside
# mountos_admin/mountos_data — same shared-instance shape as the dataserv rule above,
# gated on admin_client_enabled since the SG only exists then.
resource "aws_vpc_security_group_ingress_rule" "rds_from_admin_client" {
  count                        = local.provision_rds && var.admin_client_enabled ? 1 : 0
  security_group_id            = aws_security_group.rds[0].id
  referenced_security_group_id = aws_security_group.admin_client[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "postgres from admin-client (native-login portal DB)"
}

# Fresh per-apply-lifecycle suffix (not timestamp(), which would diff every
# plan) so a final snapshot from a prior destroy doesn't collide with the
# identifier a later destroy tries to reuse in the same account/region.
resource "random_id" "admin_final_snapshot" {
  count       = local.provision_rds ? 1 : 0
  byte_length = 4
}

# Non-production only: manage_master_user_password's Secrets-Manager-managed
# rotation (every 7 days by default, not configurable to "off" on the AWS
# provider version this package pins - see the comment on
# manage_master_user_password below) silently breaks every DSN that isn't
# re-read live from Secrets Manager between rotations. appserv/dataserv read
# their DSN from Vault and admin-client from a literal env var, neither on a
# 7-day refresh cycle, so production's rotation is exactly wrong for a demo
# environment meant to sit idle between test rounds. Generated fresh on every
# apply (ephemeral: never written to tfstate), but only actually WRITTEN to
# RDS/Secrets Manager when var.admin_demo_password_version changes from its
# last-applied value - see that variable's description.
ephemeral "random_password" "admin_demo" {
  count   = local.provision_rds && var.mode != "production" ? 1 : 0
  length  = 32
  special = false # keep it DSN/URL-safe without needing urlencode at seed time
}

# Stable, Terraform-managed secret (distinct from manage_master_user_password's
# AWS-managed one, which doesn't exist in non-production mode) that
# bootstrap/seed-vault.sh reads via the SAME admin_db_secret_arn output it
# already uses for production - same {"password": "..."} shape as the
# AWS-managed secret, so seed-vault.sh needs no changes for either mode.
resource "aws_secretsmanager_secret" "admin_demo_password" {
  count = local.provision_rds && var.mode != "production" ? 1 : 0
  name  = "${local.name_root}-admin-demo-password"
  tags  = { Name = "${local.name_root}-admin-demo-password" }
}

resource "aws_secretsmanager_secret_version" "admin_demo_password" {
  count                     = local.provision_rds && var.mode != "production" ? 1 : 0
  secret_id                 = aws_secretsmanager_secret.admin_demo_password[0].id
  secret_string_wo          = jsonencode({ password = ephemeral.random_password.admin_demo[0].result })
  secret_string_wo_version  = var.admin_demo_password_version
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

  # Production: AWS generates and rotates the master password in Secrets
  # Manager; it is never a Terraform value, so it never lands in tfstate or
  # user_data. The secret ARN is read at seed time (see
  # bootstrap/seed-vault.sh) by the operator, not by instances — appserv gets
  # its DSN from Vault, never from Secrets Manager directly.
  #
  # Non-production: manage_master_user_password is off instead, because this
  # AWS provider version (~> 5.0) can't turn off that Secrets-Manager-managed
  # rotation (aws_secretsmanager_secret_rotation's rotation_enabled attribute
  # is read-only until provider v6.x) - the fixed 7-day cycle it forces would
  # routinely break every DSN sitting idle between demo rounds. password_wo
  # (write-only: same "never in tfstate" property as the managed-password
  # path above) is fed from the ephemeral random_password above instead, and
  # only re-applied when admin_demo_password_version is bumped deliberately.
  #
  # The two branches below must resolve to `true`/`null`, not `true`/`false`
  # or a real value/`""` - the AWS provider's ConflictsWith check on
  # manage_master_user_password vs. password_wo fires whenever BOTH
  # arguments are non-null, even if one is a "false"/empty placeholder that
  # was never meant to take effect. A literal `var.mode == "production"`
  # here (a plain bool, never null) breaks that check; the ternary form does
  # not.
  manage_master_user_password = var.mode == "production" ? true : null
  password_wo                 = var.mode != "production" ? ephemeral.random_password.admin_demo[0].result : null
  password_wo_version         = var.mode != "production" ? var.admin_demo_password_version : null

  # No prevent_destroy: deletion_protection (above) is the real safety net and
  # is correctly mode-gated to production only. prevent_destroy is a Terraform
  # meta-argument that can't take a variable, so it would block dev/staging
  # teardown too if set unconditionally.
}
