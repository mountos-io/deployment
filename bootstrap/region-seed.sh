#!/usr/bin/env bash
# Region bootstrap (run ONCE, operator-side): generate fresh dataserv/gcserv keys
# plus blockserv/hdfsserv/s3gatewayserv keys (region-scoped service keypairs are
# UNCONDITIONAL — generated and fanned out regardless of whether block_enable /
# hdfs_enable / s3gateway_enable actually runs the service in this region), seed
# the REGION Vault, and FAN OUT service-verifiers between the hub and region
# Vaults so SRPC registration verifies both ways (the hub trusts the new region
# services; the region trusts the hub's appserv). Idempotent and NON-DESTRUCTIVE.
#
# Required env:
#   REGION_VAULT_ADDR + REGION_VAULT_TOKEN  region Vault (terraform output region_vault_addr + its operator-init token)
#   HUB_VAULT_ADDR    + HUB_VAULT_TOKEN      hub Vault (read appserv verifier, add region verifiers)
#   REGION_DB_URL                            mountos_data DSN (byo mode), or — on AWS in provision-rds mode —
#                                             REGION_DB_HOST + REGION_DB_SECRET_ARN (terraform output; AWS manages
#                                             the master password in Secrets Manager, this script fetches it and
#                                             builds the DSN; requires aws CLI credentials with secretsmanager:GetSecretValue).
#                                             GCP/Azure: their region_db_url output is already a complete DSN — just
#                                             set REGION_DB_URL directly, same as byo mode.
# Vault now serves TLS. Set VAULT_CACERT to the CA PEM before running:
#   AWS:   aws ssm get-parameter --name /mountos/<hub|region>/vault-ca --query Parameter.Value --output text > vault-ca.pem
#   GCP:   gcloud secrets versions access latest --secret=mountos-<hub|region>-vault-ca > vault-ca.pem
#   Azure: az keyvault secret show --vault-name <hub|region-key-vault> --name mountos-<hub|region>-vault-ca --query value -o tsv > vault-ca.pem
# This seed talks to BOTH region and hub Vault — VAULT_CACERT may be a concatenation of both CAs.
set -euo pipefail
umask 077 # secrets file is created mode 0600

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
{ set -a; source "$here/answers.env"; set +a; } || { echo "run 'make interview' first"; exit 1; }

: "${REGION_VAULT_ADDR:?set REGION_VAULT_ADDR (terraform output region_vault_addr)}"
: "${REGION_VAULT_TOKEN:?export REGION_VAULT_TOKEN (region Vault admin/bootstrap token)}"
: "${HUB_VAULT_ADDR:?set HUB_VAULT_ADDR (the hub Vault address)}"
: "${HUB_VAULT_TOKEN:?export HUB_VAULT_TOKEN (hub Vault token)}"

if [[ -z "${REGION_DB_URL:-}" ]]; then
  : "${REGION_DB_HOST:?set REGION_DB_URL (byo) or REGION_DB_HOST + REGION_DB_SECRET_ARN (terraform output, provision-rds)}"
  : "${REGION_DB_SECRET_ARN:?set REGION_DB_SECRET_ARN (terraform output region_db_secret_arn)}"
  echo "==> fetching the AWS-managed region DB master password from Secrets Manager"
  region_db_pw="$(aws secretsmanager get-secret-value --secret-id "$REGION_DB_SECRET_ARN" --query SecretString --output text | jq -r .password)"
  region_db_user="$(jq -rn --arg u "${REGION_DB_USERNAME:-mountos}" '$u|@uri')"
  # Env, not --arg: see seed-vault.sh's equivalent line for why.
  region_db_pw_enc="$(REGION_DB_PW="$region_db_pw" jq -rn 'env.REGION_DB_PW|@uri')"
  REGION_DB_URL="postgresql://${region_db_user}:${region_db_pw_enc}@${REGION_DB_HOST}/mountos_data?sslmode=require"
fi

secrets="$here/region-secrets.local.json"
if [[ ! -f "$secrets" ]]; then
  echo "==> generating region key material -> region-secrets.local.json"
  if command -v mos-keygen >/dev/null 2>&1; then mos-keygen > "$secrets"
  else go -C "$here/bootstrap/keygen" run . > "$secrets"; fi
fi
sec() { jq -r ".$1" "$secrets"; }
cacert_opt=()
[[ -n "${VAULT_CACERT:-}" ]] && cacert_opt=(--cacert "$VAULT_CACERT")
rv() { curl -sf "${cacert_opt[@]}" -H "X-Vault-Token: $REGION_VAULT_TOKEN" "$@"; }
hv() { curl -sf "${cacert_opt[@]}" -H "X-Vault-Token: $HUB_VAULT_TOKEN" "$@"; }
# Like rv()/hv(), but tolerate 404 (KVv2 path not written yet) as an empty
# read, rather than -f masking a real auth/server error behind the same
# "empty" shape jq would coerce a 404 body into.
_v_opt() {
  local token="$1" resp status body
  shift
  resp="$(curl -s -w '\n%{http_code}' "${cacert_opt[@]}" -H "X-Vault-Token: $token" "$@")"
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
rv_opt() { _v_opt "$REGION_VAULT_TOKEN" "$@"; }
hv_opt() { _v_opt "$HUB_VAULT_TOKEN" "$@"; }

# Shared value pulled from the hub Vault.
appserv_vk="$(hv_opt "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -r '.data.data.appserv // empty')"
[[ -n "$appserv_vk" ]] || { echo "hub service-verifiers has no appserv key — run 'make bootstrap' on the hub first"; exit 1; }

echo "==> region Vault: enable KVv2 + AppRole (idempotent)"
rv -X POST "$REGION_VAULT_ADDR/v1/sys/mounts/mountos" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null || true
rv -X POST "$REGION_VAULT_ADDR/v1/sys/auth/approle"   -d '{"type":"approle"}' >/dev/null || true
rv -X PUT  "$REGION_VAULT_ADDR/v1/sys/policies/acl/region" \
  -d "$(jq -n '{policy:"path \"mountos/data/*\" { capabilities=[\"read\"] }"}')" >/dev/null

echo "==> region Vault: dataserv + gcserv configs (mountos_data DSN + Noise keys)"
# Env, not --arg: DB_URL and the signing key are real secrets (see
# seed-vault.sh's equivalent write for why).
for svc in dataserv gcserv; do
  DB_DIALECT="$ADMIN_DB_DIALECT" DB_URL="$REGION_DB_URL" DB_VER="$ADMIN_DB_PROVIDER_VERSION" \
    SIGN_KEY="$(sec "${svc}_signing")" VERIFY_KEY="$(sec "${svc}_verification")" \
    jq -n '{data:{DB_DIALECT:env.DB_DIALECT,DB_PROVIDER:env.DB_DIALECT,DB_URL:env.DB_URL,DB_PROVIDER_VERSION:env.DB_VER,
            ED25519_SIGNING_KEY:env.SIGN_KEY,ED25519_VERIFICATION_KEY:env.VERIFY_KEY}}' \
    | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/$svc" -d @- >/dev/null
done

echo "==> region Vault: blockserv + hdfsserv + s3gatewayserv keys (no DB; UNCONDITIONAL — keyed"
echo "    regardless of block_enable/hdfs_enable/s3gateway_enable, only running the service is opt-in)"
for svc in blockserv hdfsserv s3gatewayserv; do
  SIGN_KEY="$(sec "${svc}_signing")" VERIFY_KEY="$(sec "${svc}_verification")" \
    jq -n '{data:{ED25519_SIGNING_KEY:env.SIGN_KEY, ED25519_VERIFICATION_KEY:env.VERIFY_KEY}}' \
    | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/$svc" -d @- >/dev/null
done

echo "==> region Vault: api-master (region-independent — generated fresh for THIS region, never"
echo "    shared with the hub or other regions; single field 'key'; written ONCE, never overwritten"
echo "    by a re-run — rotate deliberately via the Admin SDK vault operation, not this script)"
existing_am="$(rv_opt "$REGION_VAULT_ADDR/v1/mountos/data/api-master" | jq -r '.data.data.key // empty')"
if [[ -z "$existing_am" ]]; then
  API_MASTER_KEY="$(sec api_master)" jq -n '{data:{key:env.API_MASTER_KEY}}' \
    | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/api-master" -d @- >/dev/null
else
  echo "    api-master already present in this region's Vault; leaving it as-is"
fi

echo "==> region Vault: service-verifiers (appserv from hub + dataserv/gcserv/blockserv/hdfsserv/s3gatewayserv; MERGE)"
cur_rv="$(rv_opt "$REGION_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -c '.data.data // {}')"
AV="$appserv_vk" DV="$(sec dataserv_verification)" GV="$(sec gcserv_verification)" \
  BV="$(sec blockserv_verification)" HDV="$(sec hdfsserv_verification)" SV="$(sec s3gatewayserv_verification)" \
  jq -n --argjson cur "$cur_rv" \
  '{data: ($cur + {appserv:env.AV, dataserv:env.DV, gcserv:env.GV, blockserv:env.BV, hdfsserv:env.HDV, s3gatewayserv:env.SV})}' \
  | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/service-verifiers" -d @- >/dev/null

echo "==> hub Vault: add region verifiers (fan-out; MERGE so appserv stays)"
hub_v="$(hv_opt "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -c '.data.data // {}')"
DV="$(sec dataserv_verification)" GV="$(sec gcserv_verification)" \
  BV="$(sec blockserv_verification)" HDV="$(sec hdfsserv_verification)" SV="$(sec s3gatewayserv_verification)" \
  jq -n --argjson cur "$hub_v" \
  '{data: ($cur + {dataserv:env.DV, gcserv:env.GV, blockserv:env.BV, hdfsserv:env.HDV, s3gatewayserv:env.SV})}' \
  | hv -X POST "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" -d @- >/dev/null

echo "==> region AppRole (shared by dataserv/gcserv and, when enabled, blockserv/hdfsserv/s3gatewayserv)"
rv -X POST "$REGION_VAULT_ADDR/v1/auth/approle/role/region" -d '{"token_policies":"region","token_ttl":"1h"}' >/dev/null
role_id="$(rv "$REGION_VAULT_ADDR/v1/auth/approle/role/region/role-id" | jq -r .data.role_id)"
echo "region_vault_role_id=$role_id"
echo "  -> set region_vault_role_id (+ a wrapped secret_id) in tfvars, then re-run 'make apply'."
echo "     After dataserv registers over SRPC, the region's uno cluster flips ready."
echo "     blockserv/hdfsserv/s3gatewayserv keys are already seeded above; set block_enable/"
echo "     hdfs_enable/s3gateway_enable=true in tfvars only for the ones you want RUNNING."
