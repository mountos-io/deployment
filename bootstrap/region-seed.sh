#!/usr/bin/env bash
# Region bootstrap (run ONCE, operator-side): generate fresh dataserv/gcserv keys
# plus blockserv keys (region-scoped service keypairs are UNCONDITIONAL —
# generated and fanned out regardless of whether block_enable actually runs the
# service in this region), seed
# the REGION secret store, and FAN OUT service-verifiers between the hub and
# region stores so SRPC registration verifies both ways (the hub trusts the new
# region services; the region trusts the hub's appserv). Idempotent and
# NON-DESTRUCTIVE.
#
# Store selection: REGION_VAULT_PROVIDER (default: VAULT_PROVIDER) for the
# region store, VAULT_PROVIDER for the hub store. Same values as seed-vault.sh
# (aws | hashicorp | gcp | azure — cloud-native stores are never launched, and
# a byo HashiCorp Vault is never launched either; we only write values).
# NOTE (aws/gcp): hub and region in the same account/region/project share ONE
# physical namespace — the fan-out then converges on a single service-verifiers
# secret, which is correct and idempotent. Isolation is enforced by IAM.
#   hashicorp  REGION_VAULT_ADDR + REGION_VAULT_TOKEN (and HUB_VAULT_ADDR +
#              HUB_VAULT_TOKEN when the hub store is also hashicorp).
#              Private CA: VAULT_CACERT may be a concatenation of both CAs.
#   aws        ambient `aws` CLI creds; region from VAULT_AWS_REGION/AWS_REGION.
#   gcp        VAULT_GCP_PROJECT_ID + ambient `gcloud` auth.
#   azure      VAULT_AZURE_URL (hub KV) + REGION_VAULT_AZURE_URL (region KV).
#
# REGION_DB_URL: mountos_data DSN (byo mode — the recommended production path),
# or leave empty in provisioned mode and set REGION_DB_HOST plus ONE
# cloud-specific password reference (all from `terraform output`):
#   AWS:   REGION_DB_SECRET_ARN       (Secrets Manager)
#   GCP:   REGION_DB_PASSWORD_SECRET  (Secret Manager, gcloud)
#   Azure: REGION_DB_SECRET_ID        (Key Vault, az)
# GCP/Azure caveat: the provisioned password is still a Terraform value
# (random_password) — see each cloud's rds.tf PARITY GAP note.
set -euo pipefail
umask 077 # secrets file is created mode 0600

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$here/answers.env" ]] || { echo "run 'make interview' first"; exit 1; }
# shellcheck disable=SC1091
set -a; source "$here/answers.env"; set +a

: "${VAULT_PROVIDER:?set VAULT_PROVIDER in answers.env (aws | hashicorp | gcp | azure)}"
REGION_VAULT_PROVIDER="${REGION_VAULT_PROVIDER:-$VAULT_PROVIDER}"

if [[ -z "${REGION_DB_URL:-}" ]]; then
  : "${REGION_DB_HOST:?set REGION_DB_URL (byo) or REGION_DB_HOST + a password reference (terraform output, provisioned mode)}"
  if [[ -n "${REGION_DB_SECRET_ARN:-}" ]]; then
    echo "==> fetching the AWS-managed region DB master password from Secrets Manager"
    region_db_pw="$(aws secretsmanager get-secret-value --secret-id "$REGION_DB_SECRET_ARN" --query SecretString --output text | jq -r .password)"
  elif [[ -n "${REGION_DB_PASSWORD_SECRET:-}" ]]; then
    echo "==> fetching the region DB master password from GCP Secret Manager"
    region_db_pw="$(gcloud secrets versions access latest --secret="$REGION_DB_PASSWORD_SECRET" --project="${VAULT_GCP_PROJECT_ID:?set VAULT_GCP_PROJECT_ID (pins the gcloud project)}")"
  elif [[ -n "${REGION_DB_SECRET_ID:-}" ]]; then
    echo "==> fetching the region DB master password from Azure Key Vault"
    region_db_pw="$(az keyvault secret show --id "$REGION_DB_SECRET_ID" --query value -o tsv)"
  else
    echo "set REGION_DB_SECRET_ARN (AWS) / REGION_DB_PASSWORD_SECRET (GCP) / REGION_DB_SECRET_ID (Azure), or REGION_DB_URL directly" >&2
    exit 1
  fi
  [[ -n "$region_db_pw" && "$region_db_pw" != "null" ]] || { echo "fetched an empty region DB password" >&2; exit 1; }
  region_db_user="$(jq -rn --arg u "${REGION_DB_USERNAME:-mountos}" '$u|@uri')"
  # Env, not --arg: see seed-vault.sh's equivalent line for why.
  region_db_pw_enc="$(REGION_DB_PW="$region_db_pw" jq -rn 'env.REGION_DB_PW|@uri')"
  REGION_DB_URL="postgresql://${region_db_user}:${region_db_pw_enc}@${REGION_DB_HOST}/mountos_data?sslmode=require"
fi

# Region DB engine settings default to the admin DB's, but a byo region DB may
# be a different engine/version — override with REGION_DB_DIALECT /
# REGION_DB_PROVIDER / REGION_DB_PROVIDER_VERSION.
REGION_DB_DIALECT="${REGION_DB_DIALECT:-${ADMIN_DB_DIALECT:-postgresql}}"
REGION_DB_PROVIDER="${REGION_DB_PROVIDER:-${REGION_DB_DIALECT}}"
REGION_DB_PROVIDER_VERSION="${REGION_DB_PROVIDER_VERSION:-${ADMIN_DB_PROVIDER_VERSION:?set ADMIN_DB_PROVIDER_VERSION or REGION_DB_PROVIDER_VERSION}}"

# Fail closed on a plaintext-capable byo DSN (see seed-vault.sh's equivalent
# check for the rationale and caveats).
if [[ "${REGION_DB_ALLOW_PLAINTEXT:-}" != "1" ]]; then
  case "$REGION_DB_DIALECT" in
  postgresql)
    if [[ "$REGION_DB_URL" != *sslmode=* || "$REGION_DB_URL" == *sslmode=disable* || "$REGION_DB_URL" == *sslmode=allow* || "$REGION_DB_URL" == *sslmode=prefer* ]]; then
      echo "ERROR: REGION_DB_URL must carry sslmode=verify-full (preferred) or sslmode=require." >&2
      echo "       sslmode absent/disable/allow/prefer can silently downgrade to plaintext." >&2
      echo "       Set REGION_DB_ALLOW_PLAINTEXT=1 to override on an isolated dev network." >&2
      exit 1
    fi
    ;;
  mysql)
    if [[ "$REGION_DB_URL" != *tls=* && "$REGION_DB_URL" != *ssl-mode=* ]]; then
      echo "ERROR: REGION_DB_URL (mysql) has no tls=/ssl-mode= parameter — the connection may be plaintext." >&2
      echo "       Set REGION_DB_ALLOW_PLAINTEXT=1 to override on an isolated dev network." >&2
      exit 1
    fi
    ;;
  esac
fi

secrets="$here/region-secrets.local.json"
if [[ ! -f "$secrets" ]]; then
  echo "==> generating region key material -> region-secrets.local.json"
  # Temp + mv: a keygen crash must not leave a truncated file (see seed-vault.sh).
  if command -v mos-keygen >/dev/null 2>&1; then mos-keygen > "$secrets.tmp"
  else go -C "$here/bootstrap/keygen" run . > "$secrets.tmp"; fi
  mv "$secrets.tmp" "$secrets"
fi
# -e: a missing/null key must fail loudly, not seed the literal string "null".
sec() { jq -er ".$1" "$secrets" || { echo "region-secrets.local.json is missing '$1' — regenerate with a current mos-keygen" >&2; exit 1; }; }

# ---------------------------------------------------------------------------
# Store layer: hub_kv_get/hub_kv_put (hub store) and rkv_get/rkv_put (region
# store), uniform JSON-object semantics; see seed-vault.sh's store layer for
# the per-provider name encodings (they mirror mountos-servers/internal/secrets).
# RESOURCE_PREFIX (optional, answers.env) renames the "mountos" root to
# "mountos-<prefix>" in every encoding below, same value for hub and region.
# ---------------------------------------------------------------------------
name_root="mountos${RESOURCE_PREFIX:+-$RESOURCE_PREFIX}"

cacert_opt=()
[[ -n "${VAULT_CACERT:-}" ]] && cacert_opt=(--cacert "$VAULT_CACERT")
# ${arr[@]+...}: bash 3.2 (macOS default) treats an empty array as unset under set -u.
# Token via curl -K config on a private fd, not -H argv (argv is ps-visible).
_hv_req() {
  local token="$1" tolerate_404="$2" resp status body
  shift 2
  resp="$(curl -s -w '\n%{http_code}' ${cacert_opt[@]+"${cacert_opt[@]}"} -K <(printf 'header = "X-Vault-Token: %s"\n' "$token") "$@")"
  status="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  case "$status" in
  200 | 204) printf '%s' "$body" ;;
  404) [[ "$tolerate_404" == "yes" ]] && printf '{"data":{"data":{}}}' || { echo "vault request failed (HTTP 404) for $*" >&2; return 1; } ;;
  *)
    # Body not echoed: KVv2 error responses can echo back request context and
    # the path may already hold secret material in a prior successful write.
    echo "vault request failed (HTTP $status) for $*" >&2
    return 1
    ;;
  esac
}

_check_https() { # $1 = var name, $2 = value
  if [[ "$2" != https://* && "${VAULT_ALLOW_HTTP:-}" != "1" ]]; then
    echo "ERROR: $1 must be https:// — this script sends bootstrap tokens and key material to it." >&2
    echo "       Set VAULT_ALLOW_HTTP=1 to override on an isolated dev network." >&2
    exit 1
  fi
}

# $1 = provider, $2 = role (hub|region). Defines <role>_kv_get / <role>_kv_put.
_bind_store() {
  local provider="$1" role="$2"
  case "$provider" in
  hashicorp)
    if [[ "$role" == "hub" ]]; then
      # Default to the hub-bootstrap names so a single-Vault-per-scope setup
      # needs no duplicate exports.
      HUB_VAULT_ADDR="${HUB_VAULT_ADDR:-${VAULT_ADDR:-}}"
      HUB_VAULT_TOKEN="${HUB_VAULT_TOKEN:-${VAULT_TOKEN:-}}"
      : "${HUB_VAULT_ADDR:?set HUB_VAULT_ADDR (or VAULT_ADDR — the hub byo Vault address)}"
      : "${HUB_VAULT_TOKEN:?export HUB_VAULT_TOKEN (or VAULT_TOKEN — hub Vault token)}"
      _check_https HUB_VAULT_ADDR "$HUB_VAULT_ADDR"
      hub_kv_get() { _hv_req "$HUB_VAULT_TOKEN" yes "$HUB_VAULT_ADDR/v1/$name_root/data/$1" | jq -c '.data.data // {}'; }
      hub_kv_put() { jq -c '{data: .}' | _hv_req "$HUB_VAULT_TOKEN" no -X POST "$HUB_VAULT_ADDR/v1/$name_root/data/$1" -d @- >/dev/null; }
    else
      : "${REGION_VAULT_ADDR:?set REGION_VAULT_ADDR (the region byo Vault address)}"
      : "${REGION_VAULT_TOKEN:?export REGION_VAULT_TOKEN (region Vault admin/bootstrap token)}"
      _check_https REGION_VAULT_ADDR "$REGION_VAULT_ADDR"
      rkv_get() { _hv_req "$REGION_VAULT_TOKEN" yes "$REGION_VAULT_ADDR/v1/$name_root/data/$1" | jq -c '.data.data // {}'; }
      rkv_put() { jq -c '{data: .}' | _hv_req "$REGION_VAULT_TOKEN" no -X POST "$REGION_VAULT_ADDR/v1/$name_root/data/$1" -d @- >/dev/null; }
    fi
    ;;
  aws)
    SM_REGION="${VAULT_AWS_REGION:-${AWS_REGION:?set VAULT_AWS_REGION or AWS_REGION}}"
    # {} ONLY on genuine not-found; any other failure hard-fails — a failure
    # mistaken for "absent" would wipe merges (service-verifiers) or overwrite
    # write-once secrets (api-master).
    _sm_get() {
      local out
      if out="$(aws secretsmanager get-secret-value --region "$SM_REGION" \
        --secret-id "$name_root/$1" --query SecretString --output text 2>&1)"; then
        jq -c . <<<"$out" 2>/dev/null || { echo "$name_root/$1 holds non-JSON content" >&2; return 1; }
      elif [[ "$out" == *ResourceNotFoundException* ]]; then
        printf '{}'
      else
        echo "secretsmanager read failed for $name_root/$1: $out" >&2
        return 1
      fi
    }
    _sm_put() {
      local name="$name_root/$1"
      # --secret-string file:///dev/stdin keeps the payload out of argv (ps-visible).
      if aws secretsmanager describe-secret --region "$SM_REGION" --secret-id "$name" >/dev/null 2>&1; then
        aws secretsmanager put-secret-value --region "$SM_REGION" --secret-id "$name" \
          --secret-string file:///dev/stdin >/dev/null
      else
        aws secretsmanager create-secret --region "$SM_REGION" --name "$name" \
          --secret-string file:///dev/stdin >/dev/null
      fi
    }
    if [[ "$role" == "hub" ]]; then hub_kv_get() { _sm_get "$@"; }; hub_kv_put() { _sm_put "$@"; }
    else rkv_get() { _sm_get "$@"; }; rkv_put() { _sm_put "$@"; }; fi
    ;;
  gcp)
    : "${VAULT_GCP_PROJECT_ID:?set VAULT_GCP_PROJECT_ID}"
    # See _sm_get: {} ONLY on genuine not-found.
    _gsm_get() {
      local out
      if out="$(gcloud secrets versions access latest --secret="${name_root}__${1//\//__}" \
        --project="$VAULT_GCP_PROJECT_ID" 2>&1)"; then
        jq -c . <<<"$out" 2>/dev/null || { echo "${name_root}__${1//\//__} holds non-JSON content" >&2; return 1; }
      elif [[ "$out" == *NOT_FOUND* || "$out" == *"not found"* ]]; then
        printf '{}'
      else
        echo "secret manager read failed for ${name_root}__${1//\//__}: $out" >&2
        return 1
      fi
    }
    _gsm_put() {
      local name="${name_root}__${1//\//__}"
      gcloud secrets describe "$name" --project="$VAULT_GCP_PROJECT_ID" >/dev/null 2>&1 \
        || gcloud secrets create "$name" --replication-policy=automatic --project="$VAULT_GCP_PROJECT_ID" >/dev/null
      gcloud secrets versions add "$name" --data-file=- --project="$VAULT_GCP_PROJECT_ID" >/dev/null
    }
    if [[ "$role" == "hub" ]]; then hub_kv_get() { _gsm_get "$@"; }; hub_kv_put() { _gsm_put "$@"; }
    else rkv_get() { _gsm_get "$@"; }; rkv_put() { _gsm_put "$@"; }; fi
    ;;
  azure)
    local url_var url
    if [[ "$role" == "hub" ]]; then url_var="VAULT_AZURE_URL"; else url_var="REGION_VAULT_AZURE_URL"; fi
    url="${!url_var:?set $url_var (Key Vault URL)}"
    # See _sm_get: {} ONLY on genuine not-found.
    _akv_get() { # $1 = kv url, $2 = path
      local out
      if out="$(az keyvault secret show --id "${1%/}/secrets/${name_root}--${2//\//--}" \
        --query value -o tsv 2>&1)"; then
        jq -c . <<<"$out" 2>/dev/null || { echo "${name_root}--${2//\//--} holds non-JSON content" >&2; return 1; }
      elif [[ "$out" == *SecretNotFound* ]]; then
        printf '{}'
      else
        echo "key vault read failed for ${name_root}--${2//\//--}: $out" >&2
        return 1
      fi
    }
    _akv_put() { # $1 = kv url, $2 = path; --file keeps the payload out of argv.
      az keyvault secret set --vault-name "$(sed -E 's#https://([^./]+)\..*#\1#' <<<"$1")" \
        --name "${name_root}--${2//\//--}" --file <(cat) --encoding utf-8 >/dev/null
    }
    if [[ "$role" == "hub" ]]; then
      hub_kv_get() { _akv_get "$VAULT_AZURE_URL" "$@"; }
      hub_kv_put() { _akv_put "$VAULT_AZURE_URL" "$@"; }
    else
      rkv_get() { _akv_get "$REGION_VAULT_AZURE_URL" "$@"; }
      rkv_put() { _akv_put "$REGION_VAULT_AZURE_URL" "$@"; }
    fi
    ;;
  *)
    echo "unknown secret store provider '$provider' (aws | hashicorp | gcp | azure)" >&2
    exit 1
    ;;
  esac
}

_bind_store "$VAULT_PROVIDER" hub
_bind_store "$REGION_VAULT_PROVIDER" region

# hashicorp/hashicorp with ONE Vault would collapse the permission matrix:
# both AppRole policies read mountos/data/*, so appserv could read api-master
# and region services could read the appserv secret. Unlike the shared
# aws/gcp namespace there is no IAM backstop — refuse.
if [[ "$VAULT_PROVIDER" == "hashicorp" && "$REGION_VAULT_PROVIDER" == "hashicorp" \
  && "${HUB_VAULT_ADDR%/}" == "${REGION_VAULT_ADDR%/}" ]]; then
  echo "ERROR: the region byo Vault must be a different Vault (or namespace endpoint) than the hub's —" >&2
  echo "       one shared mountos/data/* KVv2 would let appserv read api-master and region services" >&2
  echo "       read the appserv secret. Use a second cluster or a separate namespace base URL." >&2
  exit 1
fi

# Shared value pulled from the hub store. Assignment (not a pipeline through
# jq): a store read failure must abort here, never look like "absent".
hub_sv_json="$(hub_kv_get service-verifiers)"
appserv_vk="$(jq -r '.appserv // empty' <<<"$hub_sv_json")"
[[ -n "$appserv_vk" ]] || { echo "hub service-verifiers has no appserv key — run 'make bootstrap' on the hub first"; exit 1; }

if [[ "$REGION_VAULT_PROVIDER" == "hashicorp" ]]; then
  echo "==> region Vault: enable KVv2 + AppRole (idempotent)"
  # Re-runs get HTTP 400 "path already in use" — expected, hence the quiet || true.
  _hv_req "$REGION_VAULT_TOKEN" no -X POST "$REGION_VAULT_ADDR/v1/sys/mounts/$name_root" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null 2>&1 || true
  _hv_req "$REGION_VAULT_TOKEN" no -X POST "$REGION_VAULT_ADDR/v1/sys/auth/approle" -d '{"type":"approle"}' >/dev/null 2>&1 || true
  # Read everything region-scoped, plus the writes the services actually do:
  # dataserv/gcserv create+rotate per-volume credentials (s3creds/volcreds)
  # and gcserv rotates api-master — read-only here would 403 volume creation
  # at runtime (boot would still succeed, masking it).
  _hv_req "$REGION_VAULT_TOKEN" no -X PUT "$REGION_VAULT_ADDR/v1/sys/policies/acl/region" \
    -d "$(jq -n --arg root "$name_root" '{policy: ("path \"\($root)/data/*\" { capabilities=[\"read\"] }\npath \"\($root)/data/s3creds/*\" { capabilities=[\"create\",\"read\",\"update\",\"delete\"] }\npath \"\($root)/data/volcreds/*\" { capabilities=[\"create\",\"read\",\"update\",\"delete\"] }\npath \"\($root)/data/api-master\" { capabilities=[\"create\",\"read\",\"update\"] }")}')" >/dev/null
fi

echo "==> region store: dataserv + gcserv configs (mountos_data DSN + Noise keys)"
# Env, not --arg: DB_URL and the signing key are real secrets (see
# seed-vault.sh's equivalent write for why).
for svc in dataserv gcserv; do
  DB_DIALECT="$REGION_DB_DIALECT" DB_PROV="$REGION_DB_PROVIDER" \
    DB_URL="$REGION_DB_URL" DB_VER="$REGION_DB_PROVIDER_VERSION" \
    SIGN_KEY="$(sec "${svc}_signing")" VERIFY_KEY="$(sec "${svc}_verification")" \
    jq -n '{DB_DIALECT:env.DB_DIALECT,DB_PROVIDER:env.DB_PROV,DB_URL:env.DB_URL,DB_PROVIDER_VERSION:env.DB_VER,
            ED25519_SIGNING_KEY:env.SIGN_KEY,ED25519_VERIFICATION_KEY:env.VERIFY_KEY}' \
    | rkv_put "$svc"
done

echo "==> region store: blockserv keys (no DB; UNCONDITIONAL — keyed"
echo "    regardless of block_enable, only running the service is opt-in)"
SIGN_KEY="$(sec blockserv_signing)" VERIFY_KEY="$(sec blockserv_verification)" \
  jq -n '{ED25519_SIGNING_KEY:env.SIGN_KEY, ED25519_VERIFICATION_KEY:env.VERIFY_KEY}' \
  | rkv_put blockserv

echo "==> region store: api-master (region-independent — generated fresh for THIS region, never"
echo "    shared with the hub or other regions; single field 'key'; written ONCE, never overwritten"
echo "    by a re-run — rotate deliberately via the Admin SDK vault operation, not this script)"
# Assignment first (not a pipeline through jq): a read failure aborts via
# set -e instead of masquerading as "absent" and overwriting a LIVE api-master
# (which would break every issued API key in the region).
am_json="$(rkv_get api-master)"
existing_am="$(jq -r '.key // empty' <<<"$am_json")"
if [[ -z "$existing_am" ]]; then
  API_MASTER_KEY="$(sec api_master)" jq -n '{key:env.API_MASTER_KEY}' | rkv_put api-master
else
  echo "    api-master already present in this region's store; leaving it as-is"
fi

echo "==> region store: service-verifiers (appserv from hub + dataserv/gcserv/blockserv; MERGE)"
cur_rv="$(rkv_get service-verifiers)"
[[ -n "$cur_rv" ]] || { echo "region service-verifiers read failed" >&2; exit 1; }
AV="$appserv_vk" DV="$(sec dataserv_verification)" GV="$(sec gcserv_verification)" \
  BV="$(sec blockserv_verification)" \
  jq -n --argjson cur "$cur_rv" \
  '$cur + {appserv:env.AV, dataserv:env.DV, gcserv:env.GV, blockserv:env.BV}' \
  | rkv_put service-verifiers

echo "==> hub store: add region verifiers (fan-out; MERGE so appserv stays)"
hub_v="$(hub_kv_get service-verifiers)"
[[ -n "$hub_v" ]] || { echo "hub service-verifiers read failed" >&2; exit 1; }
DV="$(sec dataserv_verification)" GV="$(sec gcserv_verification)" \
  BV="$(sec blockserv_verification)" \
  jq -n --argjson cur "$hub_v" \
  '$cur + {dataserv:env.DV, gcserv:env.GV, blockserv:env.BV}' \
  | hub_kv_put service-verifiers

if [[ "$REGION_VAULT_PROVIDER" == "hashicorp" ]]; then
  echo "==> region AppRole (shared by dataserv/gcserv and, when enabled, blockserv)"
  _hv_req "$REGION_VAULT_TOKEN" no -X POST "$REGION_VAULT_ADDR/v1/auth/approle/role/region" -d '{"token_policies":"region","token_ttl":"1h"}' >/dev/null
  role_id="$(_hv_req "$REGION_VAULT_TOKEN" no "$REGION_VAULT_ADDR/v1/auth/approle/role/region/role-id" | jq -r .data.role_id)"
  echo "region_vault_role_id=$role_id"
  echo "  -> set region_vault_role_id (+ a wrapped secret_id) in tfvars, then re-run 'make apply'."
else
  echo "==> done. Region instances read the store with their platform identity (no AppRole/token)."
fi
echo "     After dataserv registers over SRPC, the region's uno cluster flips ready."
echo "     blockserv keys are already seeded above; set block_enable=true in tfvars"
echo "     only if you want it RUNNING."
