#!/usr/bin/env bash
# Block bootstrap (run ONCE, operator-side; only when blockserv is enabled):
# generate fresh blockserv keys, write them to the REGION Vault (mountos/blockserv),
# and fan out the blockserv verifier to BOTH the region and hub Vaults so SRPC
# registration verifies. blockserv reuses the region AppRole (policy mountos/data/*),
# so no new role is created here. Idempotent and NON-DESTRUCTIVE.
#
# Required env:
#   REGION_VAULT_ADDR + REGION_VAULT_TOKEN
#   HUB_VAULT_ADDR    + HUB_VAULT_TOKEN
# Vault now serves TLS. Set VAULT_CACERT to the CA PEM before running (fetch via:
#   aws ssm get-parameter --name /mountos/<hub|region>/vault-ca --query Parameter.Value --output text > vault-ca.pem).
# This seed talks to BOTH region and hub Vault — VAULT_CACERT may be a concatenation of both CAs.
set -euo pipefail
umask 077 # secrets file is created mode 0600

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${REGION_VAULT_ADDR:?set REGION_VAULT_ADDR (terraform output region_vault_addr)}"
: "${REGION_VAULT_TOKEN:?export REGION_VAULT_TOKEN}"
: "${HUB_VAULT_ADDR:?set HUB_VAULT_ADDR}"
: "${HUB_VAULT_TOKEN:?export HUB_VAULT_TOKEN}"

secrets="$here/block-secrets.local.json"
if [[ ! -f "$secrets" ]]; then
  echo "==> generating blockserv key material -> block-secrets.local.json"
  if command -v mos-keygen >/dev/null 2>&1; then mos-keygen > "$secrets"
  else go -C "$here/bootstrap/keygen" run . > "$secrets"; fi
fi
sec() { jq -r ".$1" "$secrets"; }
rv() { curl -s ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} -H "X-Vault-Token: $REGION_VAULT_TOKEN" "$@"; }
hv() { curl -s ${VAULT_CACERT:+--cacert "$VAULT_CACERT"} -H "X-Vault-Token: $HUB_VAULT_TOKEN" "$@"; }

bvk="$(sec blockserv_verification)"

echo "==> region Vault: mountos/blockserv keys (no DB; blockserv resolves storage via appserv)"
jq -n --arg sk "$(sec blockserv_signing)" --arg vk "$bvk" \
  '{data:{ED25519_SIGNING_KEY:$sk, ED25519_VERIFICATION_KEY:$vk}}' \
  | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/blockserv" -d @- >/dev/null

echo "==> region service-verifiers: add blockserv (MERGE)"
cur_r="$(rv "$REGION_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -c '.data.data // {}')"
jq -n --argjson cur "$cur_r" --arg bv "$bvk" '{data: ($cur + {blockserv:$bv})}' \
  | rv -X POST "$REGION_VAULT_ADDR/v1/mountos/data/service-verifiers" -d @- >/dev/null

echo "==> hub service-verifiers: add blockserv (fan-out; MERGE so existing keys stay)"
cur_h="$(hv "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" | jq -c '.data.data // {}')"
jq -n --argjson cur "$cur_h" --arg bv "$bvk" '{data: ($cur + {blockserv:$bv})}' \
  | hv -X POST "$HUB_VAULT_ADDR/v1/mountos/data/service-verifiers" -d @- >/dev/null

echo "blockserv seeded. Set block_enable=true + block_members (their BLOCK_VOLUME_IDs from the"
echo "hub block-storage provisioning) in tfvars, then 'make apply'. Members peer on 9101 and"
echo "register over SRPC; reuse the region AppRole creds (region_vault_role_id/secret_id)."
