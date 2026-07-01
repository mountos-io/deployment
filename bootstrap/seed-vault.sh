#!/usr/bin/env bash
# Operator-side bootstrap (run ONCE, from your workstation/bastion):
#   generate fresh key material -> seed Vault (KVv2) -> create the appserv AppRole.
# Idempotent and NON-DESTRUCTIVE: re-running overwrites the same paths. It does
# NOT issue a secret_id (see the role_id output note at the bottom) — deliver
# secret_id to instances via Vault response-wrapping at launch, separately.
# Instances never run this; they only READ Vault.
#
# Requires: VAULT_ADDR + VAULT_TOKEN (a short-lived admin/bootstrap token) in env.
# ADMIN_DB_URL: either set it directly (byo mode), or — on AWS in provision-rds
# mode, where AWS manages the master password in Secrets Manager and it is
# never a Terraform value — set ADMIN_DB_HOST + ADMIN_DB_SECRET_ARN (both from
# `terraform output`) and this script fetches the password + builds the DSN
# (requires `aws` CLI credentials with secretsmanager:GetSecretValue on that ARN).
# GCP/Azure: their `admin_db_url` terraform output is already a complete DSN
# (no equivalent to AWS's managed-password flow — see clouds/gcp|azure/terraform/rds.tf's
# PARITY GAP note) — just set ADMIN_DB_URL directly, same as byo mode.
# Vault now serves TLS. Set VAULT_CACERT to the CA PEM before running:
#   AWS:   aws ssm get-parameter --name /mountos/hub/vault-ca --query Parameter.Value --output text > vault-ca.pem
#   GCP:   gcloud secrets versions access latest --secret=mountos-hub-vault-ca > vault-ca.pem
#   Azure: az keyvault secret show --vault-name <hub-key-vault> --name mountos-hub-vault-ca --query value -o tsv > vault-ca.pem
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
  # Env, not --arg: the password would otherwise sit in this process's argv,
  # visible to other local users via ps/proc for the subprocess's lifetime.
  admin_db_pw_enc="$(ADMIN_DB_PW="$admin_db_pw" jq -rn 'env.ADMIN_DB_PW|@uri')"
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

cacert_opt=()
[[ -n "${VAULT_CACERT:-}" ]] && cacert_opt=(--cacert "$VAULT_CACERT")
v() { curl -sf "${cacert_opt[@]}" -H "X-Vault-Token: $VAULT_TOKEN" "$@"; }
# Like v(), but tolerates 404 (KVv2 path not written yet) as an empty read,
# rather than the -f/-s combination in v() masking a real auth/server error
# behind the same "empty" shape jq would coerce a 404 body into.
v_opt() {
  local resp status body
  resp="$(curl -s -w '\n%{http_code}' "${cacert_opt[@]}" -H "X-Vault-Token: $VAULT_TOKEN" "$@")"
  status="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "$status" in
  200) printf '%s' "$body" ;;
  404) printf '{"data":{"data":{}}}' ;;
  *)
    # Body not echoed: KVv2 error responses can echo back request context and
    # the path may already hold secret material in a prior successful write.
    echo "vault request failed (HTTP $status) for $*" >&2
    exit 1
    ;;
  esac
}

echo "==> enable KVv2 + AppRole (idempotent)"
v -X POST "$VAULT_ADDR/v1/sys/mounts/mountos" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null || true
v -X POST "$VAULT_ADDR/v1/sys/auth/approle"   -d '{"type":"approle"}' >/dev/null || true
v -X PUT  "$VAULT_ADDR/v1/sys/policies/acl/appserv" \
  -d "$(jq -n '{policy:"path \"mountos/data/*\" { capabilities=[\"read\"] }"}')" >/dev/null

echo "==> write secrets (appserv config, service-verifiers)"
# Env, not --arg/--argjson: DB_URL and the signing key are real secrets and
# would otherwise sit in this process's argv (ps-visible to other local
# users for the subprocess's lifetime).
DB_DIALECT="$ADMIN_DB_DIALECT" DB_URL="$ADMIN_DB_URL" DB_VER="$ADMIN_DB_PROVIDER_VERSION" \
  SIGN_KEY="$(sec appserv_signing)" VERIFY_KEY="$(sec appserv_verification)" \
  PUB_KEY="$(sec admin_public)" HMAC_KEY="$(sec dashboard_hmac)" \
  jq -n '{data:{DB_DIALECT:env.DB_DIALECT,DB_PROVIDER:env.DB_DIALECT,DB_URL:env.DB_URL,DB_PROVIDER_VERSION:env.DB_VER,
          ED25519_SIGNING_KEY:env.SIGN_KEY,ED25519_VERIFICATION_KEY:env.VERIFY_KEY,
          PROVIDER_VERIFICATION_KEY:env.PUB_KEY,DASHBOARD_USER_HMAC_KEY:env.HMAC_KEY}}' \
  | v -X POST "$VAULT_ADDR/v1/mountos/data/appserv" -d @- >/dev/null
# MERGE so a region fan-out (which adds dataserv/gcserv verifiers) is not wiped on re-seed.
existing_v="$(v_opt "$VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -c '.data.data // {}')"
VERIFY_KEY="$(sec appserv_verification)" jq -n --argjson cur "$existing_v" \
  '{data: ($cur + {appserv: env.VERIFY_KEY})}' \
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
