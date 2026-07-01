#!/usr/bin/env bash
# Operator-side bootstrap (run ONCE, from your workstation/bastion):
#   generate fresh key material -> seed Vault (KVv2) -> create the appserv AppRole.
# Idempotent and NON-DESTRUCTIVE: re-running overwrites the same paths and
# re-issues a secret_id. Instances never run this; they only READ Vault.
#
# Requires: VAULT_ADDR + VAULT_TOKEN (a short-lived admin/bootstrap token) in env.
# ADMIN_DB_URL: either set it directly (byo mode), or — in provision-rds mode,
# where AWS manages the master password in Secrets Manager and it is never a
# Terraform value — set ADMIN_DB_HOST + ADMIN_DB_SECRET_ARN (both from
# `terraform output`) and this script fetches the password + builds the DSN.
# Requires `aws` CLI credentials with secretsmanager:GetSecretValue on that ARN.
# Vault now serves TLS. Set VAULT_CACERT to the CA PEM before running (fetch via:
#   aws ssm get-parameter --name /mountos/hub/vault-ca --query Parameter.Value --output text > vault-ca.pem).
set -euo pipefail
umask 077 # secrets file is created mode 0600

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
{ set -a; source "$here/answers.env"; set +a; } || { echo "run 'make interview' and edit answers.env first"; exit 1; }

: "${VAULT_ADDR:?set VAULT_ADDR (terraform output vault_addr, or your managed Vault/SM address)}"
: "${VAULT_TOKEN:?export VAULT_TOKEN (a short-lived admin/bootstrap token)}"

if [[ -z "${ADMIN_DB_URL:-}" ]]; then
  : "${ADMIN_DB_HOST:?set ADMIN_DB_URL (byo) or ADMIN_DB_HOST + ADMIN_DB_SECRET_ARN (terraform output, provision-rds)}"
  : "${ADMIN_DB_SECRET_ARN:?set ADMIN_DB_SECRET_ARN (terraform output admin_db_secret_arn)}"
  echo "==> fetching the AWS-managed admin DB master password from Secrets Manager"
  admin_db_pw="$(aws secretsmanager get-secret-value --secret-id "$ADMIN_DB_SECRET_ARN" --query SecretString --output text | jq -r .password)"
  admin_db_user="$(jq -rn --arg u "${ADMIN_DB_USERNAME:-mountos}" '$u|@uri')"
  admin_db_pw_enc="$(jq -rn --arg p "$admin_db_pw" '$p|@uri')"
  ADMIN_DB_URL="postgresql://${admin_db_user}:${admin_db_pw_enc}@${ADMIN_DB_HOST}/mountos_admin?sslmode=require"
fi

secrets="$here/secrets.local.json"
if [[ ! -f "$secrets" ]]; then
  echo "==> generating fresh key material -> secrets.local.json (KEEP admin_private safe + offline)"
  # Prefer the prebuilt helper (n.sh --pkg mos-keygen); fall back to source for in-repo dev.
  if command -v mos-keygen >/dev/null 2>&1; then
    mos-keygen > "$secrets"
  else
    go -C "$here/bootstrap/keygen" run . > "$secrets"
  fi
fi
sec() { jq -r ".$1" "$secrets"; }

v() { curl -s ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} -H "X-Vault-Token: $VAULT_TOKEN" "$@"; }

echo "==> enable KVv2 + AppRole (idempotent)"
v -X POST "$VAULT_ADDR/v1/sys/mounts/mountos" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null || true
v -X POST "$VAULT_ADDR/v1/sys/auth/approle"   -d '{"type":"approle"}' >/dev/null || true
v -X PUT  "$VAULT_ADDR/v1/sys/policies/acl/appserv" \
  -d "$(jq -n '{policy:"path \"mountos/data/*\" { capabilities=[\"read\"] }"}')" >/dev/null

echo "==> write secrets (appserv config, service-verifiers)"
jq -n --arg dialect "$ADMIN_DB_DIALECT" --arg du "$ADMIN_DB_URL" --arg ver "$ADMIN_DB_PROVIDER_VERSION" \
   --arg sk "$(sec appserv_signing)" --arg vk "$(sec appserv_verification)" \
   --arg pk "$(sec admin_public)" --arg hmac "$(sec dashboard_hmac)" \
  '{data:{DB_DIALECT:$dialect,DB_PROVIDER:$dialect,DB_URL:$du,DB_PROVIDER_VERSION:$ver,
          ED25519_SIGNING_KEY:$sk,ED25519_VERIFICATION_KEY:$vk,
          PROVIDER_VERIFICATION_KEY:$pk,DASHBOARD_USER_HMAC_KEY:$hmac}}' \
  | v -X POST "$VAULT_ADDR/v1/mountos/data/appserv" -d @- >/dev/null
# MERGE so a region fan-out (which adds dataserv/gcserv verifiers) is not wiped on re-seed.
existing_v="$(v "$VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -c '.data.data // {}')"
jq -n --argjson cur "$existing_v" --arg vk "$(sec appserv_verification)" \
  '{data: ($cur + {appserv: $vk})}' \
  | v -X POST "$VAULT_ADDR/v1/mountos/data/service-verifiers" -d @- >/dev/null
# api-master is NOT seeded here: it is a region-only secret (independent per
# region, appserv has no access to it per the permission matrix) — see
# bootstrap/region-seed.sh.

echo "==> appserv AppRole"
v -X POST "$VAULT_ADDR/v1/auth/approle/role/appserv" -d '{"token_policies":"appserv","token_ttl":"1h"}' >/dev/null
role_id="$(v "$VAULT_ADDR/v1/auth/approle/role/appserv/role-id" | jq -r .data.role_id)"
echo "role_id=$role_id"
echo "  -> set this as a Terraform var; deliver the secret_id to instances via Vault"
echo "     response-wrapping at launch (single-use, short-TTL). Do NOT bake a raw secret_id into the AMI/template."
