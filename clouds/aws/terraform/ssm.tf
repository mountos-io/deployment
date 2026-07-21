# Vault AppRole secret_ids delivered to instances via SSM SecureString, out of
# user_data. Created only when the corresponding secret_id var is set; on a first
# apply before the seed runs the param is absent and cloud-init tolerates it.
resource "aws_ssm_parameter" "appserv_secret_id" {
  count  = local.hub_hashicorp && var.vault_secret_id != "" ? 1 : 0
  name   = "/${local.name_root}/appserv/vault-secret-id"
  type   = "SecureString"
  value  = var.vault_secret_id
  key_id = aws_kms_key.hub.arn
  tags   = { Name = "${local.name_root}-appserv-secret-id" }
}

resource "aws_ssm_parameter" "region_secret_id" {
  count  = local.region_hashicorp && var.region_vault_secret_id != "" ? 1 : 0
  name   = "/${local.name_root}/region/vault-secret-id"
  type   = "SecureString"
  value  = var.region_vault_secret_id
  key_id = aws_kms_key.region.arn
  tags   = { Name = "${local.name_root}-region-secret-id" }
}

# byo Vault with a PRIVATE CA (hashicorp provider only): Terraform publishes
# the operator-supplied CA so instances can trust it. Public-CA byo Vaults
# leave the pem empty (instances then use system CAs and skip the fetch).
# Intelligent-Tiering: a root+intermediate chain PEM can exceed the 4 KB
# Standard-tier value cap.
resource "aws_ssm_parameter" "hub_vault_ca_byo" {
  count = local.hub_hashicorp && var.vault_ca_pem != "" ? 1 : 0
  name  = "/${local.name_root}/hub/vault-ca"
  type  = "String"
  tier  = "Intelligent-Tiering"
  value = var.vault_ca_pem
  tags  = { Name = "${local.name_root}-hub-vault-ca" }
}

resource "aws_ssm_parameter" "region_vault_ca_byo" {
  count = local.region_hashicorp && var.region_vault_ca_pem != "" ? 1 : 0
  name  = "/${local.name_root}/region/vault-ca"
  type  = "String"
  tier  = "Intelligent-Tiering"
  value = var.region_vault_ca_pem
  tags  = { Name = "${local.name_root}-region-vault-ca" }
}
