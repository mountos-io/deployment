#!/usr/bin/env bash
# Read-only health verification against a running hub. Safe to run anytime; it
# probes only (no mutations, no destroy). Run from the operator host that holds
# secrets.local.json to include the admin-JWT smoke.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
{ set -a; source "$here/answers.env"; set +a; } || { echo "run 'make interview' first"; exit 1; }
secrets="$here/secrets.local.json"
HUB_URL="${HUB_URL:-https://$HUB_DOMAIN}"

pass=0; fail=0
ok() { echo "  ✓ $*"; pass=$((pass+1)); }
no() { echo "  ✗ $*"; fail=$((fail+1)); }

echo "init-hub verify ($HUB_URL)"

# appserv HTTP up + auth enforced
code="$(curl -s -o /dev/null -w '%{http_code}' "$HUB_URL/api/v1/accounts/list" || true)"
[[ "$code" == "401" ]] && ok "appserv HTTP up, auth enforced (unauth=401)" || no "unauth code=$code (expected 401)"

# admin-JWT smoke (proves the signed-JWT auth path end to end)
if [[ -f "$secrets" ]]; then
  # Prefer the prebuilt helper (n.sh --pkg mos-verify); fall back to source for in-repo dev.
  if command -v mos-verify >/dev/null 2>&1; then runner=(mos-verify); else runner=(go -C "$here/verify" run .); fi
  smoke="$(MOUNTOS_BASE_URL="$HUB_URL" MOUNTOS_PRIVATE_KEY="$(jq -r .admin_private "$secrets")" \
    "${runner[@]}" 2>&1 | tail -1)"
  [[ "$smoke" == OK* ]] && ok "admin-JWT smoke: $smoke" || no "admin-JWT smoke: $smoke"
else
  echo "  - admin-JWT smoke skipped (no secrets.local.json on this host)"
fi

# byo (hashicorp) Vault health (optional; only when VAULT_ADDR is exported).
# Private-CA byo Vault: set VAULT_CACERT to its PEM (same as for the seed
# scripts); public-CA Vaults need nothing extra. Cloud-native stores skip this.
if [[ -n "${VAULT_ADDR:-}" ]]; then
  cacert_opt=()
  [[ -n "${VAULT_CACERT:-}" ]] && cacert_opt=(--cacert "$VAULT_CACERT")
  # ${arr[@]+...}: bash 3.2 (macOS default) treats an empty array as unset under set -u.
  sealed="$(curl -s ${cacert_opt[@]+"${cacert_opt[@]}"} "$VAULT_ADDR/v1/sys/seal-status" | jq -r '.sealed' 2>/dev/null)"
  [[ "$sealed" == "false" ]] && ok "vault unsealed (sealed=false)" || no "vault sealed=$sealed"
fi

echo "---"
echo "verify: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
