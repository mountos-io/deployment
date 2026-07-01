# Vault AppRole secret_ids delivered to instances via SSM SecureString, out of
# user_data. Created only when the corresponding secret_id var is set; on a first
# apply before the seed runs the param is absent and cloud-init tolerates it.
resource "aws_ssm_parameter" "appserv_secret_id" {
  count  = var.vault_secret_id != "" ? 1 : 0
  name   = "/mountos/appserv/vault-secret-id"
  type   = "SecureString"
  value  = var.vault_secret_id
  key_id = aws_kms_key.hub.arn
  tags   = { Name = "mountos-appserv-secret-id" }
}

resource "aws_ssm_parameter" "region_secret_id" {
  count  = var.region_vault_secret_id != "" ? 1 : 0
  name   = "/mountos/region/vault-secret-id"
  type   = "SecureString"
  value  = var.region_vault_secret_id
  key_id = aws_kms_key.region.arn
  tags   = { Name = "mountos-region-secret-id" }
}
