#!/usr/bin/env bash
# Region bootstrap (run ONCE, operator-side): generate fresh dataserv/gcserv keys,
# seed the REGION Vault, and FAN OUT service-verifiers between the hub and region
# Vaults so SRPC registration verifies both ways (the hub trusts the new region
# services; the region trusts the hub's appserv). Idempotent and NON-DESTRUCTIVE.
#
# Required env:
#   REGION_VAULT_ADDR + REGION_VAULT_TOKEN  region Vault (terraform output region_vault_addr + its operator-init token)
#   HUB_VAULT_ADDR    + HUB_VAULT_TOKEN      hub Vault (read appserv verifier + api-master, add region verifiers)
#   REGION_DB_URL                            mountos_data DSN (terraform output region_db_url)
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
: "${REGION_DB_URL:?set REGION_DB_URL (terraform output region_db_url)}"

secrets="$here/region-secrets.local.json"
if [[ ! -f "$secrets" ]]; then
  echo "==> generating region key material -> region-secrets.local.json"
  if command -v mos-keygen >/dev/null 2>&1; then mos-keygen > "$secrets"
  else go -C "$here/bootstrap/keygen" run . > "$secrets"; fi
fi
sec() { jq -r ".$1" "$secrets"; }
rv() { curl -s ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} -H "X-Vault-Token: $REGION_VAULT_TOKEN" "$@"; }
hv() { curl -s ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} -H "X-Vault-Token: $HUB_VAULT_TOKEN" "$@"; }

# Shared values pulled from the hub Vault.
appserv_vk="$(hv "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -r '.data.data.appserv // empty')"
api_master="$(hv "$HUB_VAULT_ADDR/v1/mountos/data/api-master" | jq -r '.data.data.API_MASTER // empty')"
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
jq -n --arg am "$api_master" '{data:{API_MASTER:$am}}' \
  | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/api-master" -d @- >/dev/null

echo "==> region Vault: service-verifiers (appserv from hub + dataserv + gcserv)"
jq -n --arg av "$appserv_vk" --arg dv "$(sec dataserv_verification)" --arg gv "$(sec gcserv_verification)" \
  '{data:{appserv:$av, dataserv:$dv, gcserv:$gv}}' \
  | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/service-verifiers" -d @- >/dev/null

echo "==> hub Vault: add region verifiers (fan-out; MERGE so appserv stays)"
hub_v="$(hv "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -c '.data.data // {}')"
jq -n --argjson cur "$hub_v" --arg dv "$(sec dataserv_verification)" --arg gv "$(sec gcserv_verification)" \
  '{data: ($cur + {dataserv:$dv, gcserv:$gv})}' \
  | hv -X POST "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" -d @- >/dev/null

echo "==> region AppRole (one role for the co-located dataserv+gcserv node)"
rv -X POST "$REGION_VAULT_ADDR/v1/auth/approle/role/region" -d '{"token_policies":"region","token_ttl":"1h"}' >/dev/null
role_id="$(rv "$REGION_VAULT_ADDR/v1/auth/approle/role/region/role-id" | jq -r .data.role_id)"
echo "region_vault_role_id=$role_id"
echo "  -> set region_vault_role_id (+ a wrapped secret_id) in tfvars, then re-run 'make apply'."
echo "     After dataserv registers over SRPC, the region's uno cluster flips ready."
