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
#   REGION_DB_URL                            mountos_data DSN (byo mode), or REGION_DB_HOST + REGION_DB_SECRET_ARN
#                                             (terraform output, provision-rds mode — AWS manages the master
#                                             password in Secrets Manager; this script fetches it and builds the DSN;
#                                             requires aws CLI credentials with secretsmanager:GetSecretValue on that ARN)
# Vault now serves TLS. Set VAULT_CACERT to the CA PEM before running (fetch via:
#   aws ssm get-parameter --name /mountos/<hub|region>/vault-ca --query Parameter.Value --output text > vault-ca.pem).
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
  region_db_pw_enc="$(jq -rn --arg p "$region_db_pw" '$p|@uri')"
  REGION_DB_URL="postgresql://${region_db_user}:${region_db_pw_enc}@${REGION_DB_HOST}/mountos_data?sslmode=require"
fi

secrets="$here/region-secrets.local.json"
if [[ ! -f "$secrets" ]]; then
  echo "==> generating region key material -> region-secrets.local.json"
  if command -v mos-keygen >/dev/null 2>&1; then mos-keygen > "$secrets"
  else go -C "$here/bootstrap/keygen" run . > "$secrets"; fi
fi
sec() { jq -r ".$1" "$secrets"; }
rv() { curl -s ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} -H "X-Vault-Token: $REGION_VAULT_TOKEN" "$@"; }
hv() { curl -s ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} -H "X-Vault-Token: $HUB_VAULT_TOKEN" "$@"; }

# Shared value pulled from the hub Vault.
appserv_vk="$(hv "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -r '.data.data.appserv // empty')"
[[ -n "$appserv_vk" ]] || { echo "hub service-verifiers has no appserv key — run 'make bootstrap' on the hub first"; exit 1; }

echo "==> region Vault: enable KVv2 + AppRole (idempotent)"
rv -X POST "$REGION_VAULT_ADDR/v1/sys/mounts/mountos" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null || true
rv -X POST "$REGION_VAULT_ADDR/v1/sys/auth/approle"   -d '{"type":"approle"}' >/dev/null || true
rv -X PUT  "$REGION_VAULT_ADDR/v1/sys/policies/acl/region" \
  -d "$(jq -n '{policy:"path \"mountos/data/*\" { capabilities=[\"read\"] }"}')" >/dev/null

echo "==> region Vault: dataserv + gcserv configs (mountos_data DSN + Noise keys)"
for svc in dataserv gcserv; do
  jq -n --arg dialect "$ADMIN_DB_DIALECT" --arg du "$REGION_DB_URL" --arg ver "$ADMIN_DB_PROVIDER_VERSION" \
     --arg sk "$(sec ${svc}_signing)" --arg vk "$(sec ${svc}_verification)" \
    '{data:{DB_DIALECT:$dialect,DB_PROVIDER:$dialect,DB_URL:$du,DB_PROVIDER_VERSION:$ver,
            ED25519_SIGNING_KEY:$sk,ED25519_VERIFICATION_KEY:$vk}}' \
    | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/$svc" -d @- >/dev/null
done

echo "==> region Vault: blockserv + hdfsserv + s3gatewayserv keys (no DB; UNCONDITIONAL — keyed"
echo "    regardless of block_enable/hdfs_enable/s3gateway_enable, only running the service is opt-in)"
for svc in blockserv hdfsserv s3gatewayserv; do
  jq -n --arg sk "$(sec ${svc}_signing)" --arg vk "$(sec ${svc}_verification)" \
    '{data:{ED25519_SIGNING_KEY:$sk, ED25519_VERIFICATION_KEY:$vk}}' \
    | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/$svc" -d @- >/dev/null
done

echo "==> region Vault: api-master (region-independent — generated fresh for THIS region, never"
echo "    shared with the hub or other regions; single field 'key'; written ONCE, never overwritten"
echo "    by a re-run — rotate deliberately via the Admin SDK vault operation, not this script)"
existing_am="$(rv "$REGION_VAULT_ADDR/v1/mountos/data/api-master" | jq -r '.data.data.key // empty')"
if [[ -z "$existing_am" ]]; then
  jq -n --arg k "$(sec api_master)" '{data:{key:$k}}' \
    | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/api-master" -d @- >/dev/null
else
  echo "    api-master already present in this region's Vault; leaving it as-is"
fi

echo "==> region Vault: service-verifiers (appserv from hub + dataserv/gcserv/blockserv/hdfsserv/s3gatewayserv; MERGE)"
cur_rv="$(rv "$REGION_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -c '.data.data // {}')"
jq -n --argjson cur "$cur_rv" --arg av "$appserv_vk" \
  --arg dv "$(sec dataserv_verification)" --arg gv "$(sec gcserv_verification)" \
  --arg bv "$(sec blockserv_verification)" --arg hv "$(sec hdfsserv_verification)" --arg sv "$(sec s3gatewayserv_verification)" \
  '{data: ($cur + {appserv:$av, dataserv:$dv, gcserv:$gv, blockserv:$bv, hdfsserv:$hv, s3gatewayserv:$sv})}' \
  | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/service-verifiers" -d @- >/dev/null

echo "==> hub Vault: add region verifiers (fan-out; MERGE so appserv stays)"
hub_v="$(hv "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -c '.data.data // {}')"
jq -n --argjson cur "$hub_v" \
  --arg dv "$(sec dataserv_verification)" --arg gv "$(sec gcserv_verification)" \
  --arg bv "$(sec blockserv_verification)" --arg hv "$(sec hdfsserv_verification)" --arg sv "$(sec s3gatewayserv_verification)" \
  '{data: ($cur + {dataserv:$dv, gcserv:$gv, blockserv:$bv, hdfsserv:$hv, s3gatewayserv:$sv})}' \
  | hv -X POST "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" -d @- >/dev/null

echo "==> region AppRole (shared by dataserv/gcserv and, when enabled, blockserv/hdfsserv/s3gatewayserv)"
rv -X POST "$REGION_VAULT_ADDR/v1/auth/approle/role/region" -d '{"token_policies":"region","token_ttl":"1h"}' >/dev/null
role_id="$(rv "$REGION_VAULT_ADDR/v1/auth/approle/role/region/role-id" | jq -r .data.role_id)"
echo "region_vault_role_id=$role_id"
echo "  -> set region_vault_role_id (+ a wrapped secret_id) in tfvars, then re-run 'make apply'."
echo "     After dataserv registers over SRPC, the region's uno cluster flips ready."
echo "     blockserv/hdfsserv/s3gatewayserv keys are already seeded above; set block_enable/"
echo "     hdfs_enable/s3gateway_enable=true in tfvars only for the ones you want RUNNING."
