#!/usr/bin/env bash
# Operator-side bootstrap (run ONCE, from your workstation/bastion):
#   generate fresh key material -> seed the hub secret store -> (hashicorp only)
#   create the appserv AppRole.
# Idempotent and NON-DESTRUCTIVE: re-running overwrites the same paths.
# Instances never run this; they only READ the store.
#
# Secret store selection (VAULT_PROVIDER, from answers.env):
#   aws        cloud-native Secrets Manager (RECOMMENDED). Uses your ambient
#              `aws` CLI credentials; region from VAULT_AWS_REGION or AWS_REGION.
#              Instances read via their instance role — no AppRole, no token.
#   hashicorp  byo Vault (never launched by this package). Requires VAULT_ADDR
#              + VAULT_TOKEN (a short-lived admin/bootstrap token); enables
#              KVv2 + AppRole and prints the appserv role_id.
#   gcp        cloud-native Secret Manager. Requires VAULT_GCP_PROJECT_ID +
#              ambient `gcloud` auth.
#   azure      cloud-native Key Vault. Requires VAULT_AZURE_URL + ambient `az`
#              auth.
#
# ADMIN_DB_URL: set it directly (byo mode — the recommended production path),
# or leave it empty in provisioned-DB mode and set ADMIN_DB_HOST plus ONE
# cloud-specific password reference (all from `terraform output`); this script
# fetches the password and builds the DSN, so it never exists as a Terraform value:
#   AWS:   ADMIN_DB_SECRET_ARN       (Secrets Manager; needs secretsmanager:GetSecretValue)
#   GCP:   ADMIN_DB_PASSWORD_SECRET  (terraform output admin_db_password_secret; needs gcloud)
#   Azure: ADMIN_DB_SECRET_ID        (terraform output admin_db_secret_id; needs az)
# GCP/Azure caveat: their provisioned password is still a Terraform value
# (random_password) — see each cloud's rds.tf PARITY GAP note.
#
# hashicorp + private CA: set VAULT_CACERT to the CA PEM file before running.
set -euo pipefail
umask 077 # secrets file is created mode 0600

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$here/answers.env" ]] || { echo "run 'make interview' and edit answers.env first"; exit 1; }
# shellcheck disable=SC1091
set -a; source "$here/answers.env"; set +a

: "${VAULT_PROVIDER:?set VAULT_PROVIDER in answers.env (aws | hashicorp | gcp | azure)}"

if [[ -z "${ADMIN_DB_URL:-}" ]]; then
  : "${ADMIN_DB_HOST:?set ADMIN_DB_URL (byo) or ADMIN_DB_HOST + a password reference (terraform output, provisioned mode)}"
  if [[ -n "${ADMIN_DB_SECRET_ARN:-}" ]]; then
    echo "==> fetching the AWS-managed admin DB master password from Secrets Manager"
    admin_db_pw="$(aws secretsmanager get-secret-value --secret-id "$ADMIN_DB_SECRET_ARN" --query SecretString --output text | jq -r .password)"
  elif [[ -n "${ADMIN_DB_PASSWORD_SECRET:-}" ]]; then
    echo "==> fetching the admin DB master password from GCP Secret Manager"
    admin_db_pw="$(gcloud secrets versions access latest --secret="$ADMIN_DB_PASSWORD_SECRET" --project="${VAULT_GCP_PROJECT_ID:?set VAULT_GCP_PROJECT_ID (pins the gcloud project)}")"
  elif [[ -n "${ADMIN_DB_SECRET_ID:-}" ]]; then
    echo "==> fetching the admin DB master password from Azure Key Vault"
    admin_db_pw="$(az keyvault secret show --id "$ADMIN_DB_SECRET_ID" --query value -o tsv)"
  else
    echo "set ADMIN_DB_SECRET_ARN (AWS) / ADMIN_DB_PASSWORD_SECRET (GCP) / ADMIN_DB_SECRET_ID (Azure), or ADMIN_DB_URL directly" >&2
    exit 1
  fi
  [[ -n "$admin_db_pw" && "$admin_db_pw" != "null" ]] || { echo "fetched an empty admin DB password" >&2; exit 1; }
  admin_db_user="$(jq -rn --arg u "${ADMIN_DB_USERNAME:-mountos}" '$u|@uri')"
  # Env, not --arg: the password would otherwise sit in this process's argv,
  # visible to other local users via ps/proc for the subprocess's lifetime.
  admin_db_pw_enc="$(ADMIN_DB_PW="$admin_db_pw" jq -rn 'env.ADMIN_DB_PW|@uri')"
  ADMIN_DB_URL="postgresql://${admin_db_user}:${admin_db_pw_enc}@${ADMIN_DB_HOST}/mountos_admin?sslmode=require"
fi

# Fail closed on a plaintext-capable byo DSN. postgresql: require an sslmode
# that is at least `require` (prefer verify-full — `require` encrypts but does
# not authenticate the server). mysql: require an explicit tls/ssl-mode param.
# This is a bootstrap-time lint, not continuous enforcement — a DSN edited in
# the store later is not re-checked. Override: ADMIN_DB_ALLOW_PLAINTEXT=1
# (isolated dev networks only).
ADMIN_DB_DIALECT="${ADMIN_DB_DIALECT:-postgresql}"
if [[ "${ADMIN_DB_ALLOW_PLAINTEXT:-}" != "1" ]]; then
  case "$ADMIN_DB_DIALECT" in
  postgresql)
    if [[ "$ADMIN_DB_URL" != *sslmode=* || "$ADMIN_DB_URL" == *sslmode=disable* || "$ADMIN_DB_URL" == *sslmode=allow* || "$ADMIN_DB_URL" == *sslmode=prefer* ]]; then
      echo "ERROR: ADMIN_DB_URL must carry sslmode=verify-full (preferred) or sslmode=require." >&2
      echo "       sslmode absent/disable/allow/prefer can silently downgrade to plaintext." >&2
      echo "       Set ADMIN_DB_ALLOW_PLAINTEXT=1 to override on an isolated dev network." >&2
      exit 1
    fi
    ;;
  mysql)
    if [[ "$ADMIN_DB_URL" != *tls=* && "$ADMIN_DB_URL" != *ssl-mode=* ]]; then
      echo "ERROR: ADMIN_DB_URL (mysql) has no tls=/ssl-mode= parameter — the connection may be plaintext." >&2
      echo "       Set ADMIN_DB_ALLOW_PLAINTEXT=1 to override on an isolated dev network." >&2
      exit 1
    fi
    ;;
  esac
fi

secrets="$here/secrets.local.json"
if [[ ! -f "$secrets" ]]; then
  echo "==> generating fresh key material -> secrets.local.json (KEEP admin_private safe + offline)"
  # Prefer the prebuilt helper (n.sh --pkg mos-keygen); fall back to source for
  # in-repo dev. Write-to-temp + mv: a keygen crash must not leave a truncated
  # file that a re-run would treat as complete.
  if command -v mos-keygen >/dev/null 2>&1; then
    mos-keygen > "$secrets.tmp"
  else
    go -C "$here/bootstrap/keygen" run . > "$secrets.tmp"
  fi
  mv "$secrets.tmp" "$secrets"
fi
# -e: a missing/null key (stale keygen build, truncated file) must fail loudly,
# not seed the store with the literal string "null".
sec() { jq -er ".$1" "$secrets" || { echo "secrets.local.json is missing '$1' — regenerate with a current mos-keygen" >&2; exit 1; }; }

# ---------------------------------------------------------------------------
# Store layer. Two ops against the HUB store, uniform across providers:
#   kv_get <path>   print the secret's JSON object ({} when absent)
#   kv_put <path>   write the JSON object read from stdin
# Logical paths (appserv, service-verifiers) map to provider-native names:
#   hashicorp  mountos/data/<path>   (KVv2)
#   aws        mountos/<path>
#   gcp        mountos__<path>       (/ -> __)
#   azure      mountos--<path>       (/ -> --)
# The encodings mirror mountos-servers/internal/secrets exactly.
# ---------------------------------------------------------------------------
case "$VAULT_PROVIDER" in
hashicorp)
  : "${VAULT_ADDR:?set VAULT_ADDR (your byo Vault address)}"
  : "${VAULT_TOKEN:?export VAULT_TOKEN (a short-lived admin/bootstrap token)}"
  if [[ "$VAULT_ADDR" != https://* && "${VAULT_ALLOW_HTTP:-}" != "1" ]]; then
    echo "ERROR: VAULT_ADDR must be https:// — this script sends the bootstrap token and all key material to it." >&2
    echo "       Set VAULT_ALLOW_HTTP=1 to override on an isolated dev network." >&2
    exit 1
  fi
  cacert_opt=()
  [[ -n "${VAULT_CACERT:-}" ]] && cacert_opt=(--cacert "$VAULT_CACERT")
  # ${arr[@]+...}: bash 3.2 (macOS default) treats an empty array as unset under set -u.
  # Token via curl -K config on a private fd, not -H argv (argv is ps-visible
  # to other local users for the curl's lifetime).
  _vtok() { printf 'header = "X-Vault-Token: %s"\n' "$VAULT_TOKEN"; }
  v() { curl -sf ${cacert_opt[@]+"${cacert_opt[@]}"} -K <(_vtok) "$@"; }
  # Like v(), but tolerates 404 (KVv2 path not written yet) as an empty read,
  # rather than the -f/-s combination in v() masking a real auth/server error
  # behind the same "empty" shape jq would coerce a 404 body into.
  v_opt() {
    local resp status body
    resp="$(curl -s -w '\n%{http_code}' ${cacert_opt[@]+"${cacert_opt[@]}"} -K <(_vtok) "$@")"
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
  kv_get() { v_opt "$VAULT_ADDR/v1/mountos/data/$1" | jq -c '.data.data // {}'; }
  kv_put() { jq -c '{data: .}' | v -X POST "$VAULT_ADDR/v1/mountos/data/$1" -d @- >/dev/null; }
  ;;
aws)
  SM_REGION="${VAULT_AWS_REGION:-${AWS_REGION:?set VAULT_AWS_REGION or AWS_REGION}}"
  # {} ONLY on genuine not-found; any other failure (auth, throttle, wrong
  # region) hard-fails — a failure mistaken for "absent" would wipe merges
  # (service-verifiers) or overwrite write-once secrets (api-master).
  kv_get() {
    local out
    if out="$(aws secretsmanager get-secret-value --region "$SM_REGION" \
      --secret-id "mountos/$1" --query SecretString --output text 2>&1)"; then
      jq -c . <<<"$out" 2>/dev/null || { echo "mountos/$1 holds non-JSON content" >&2; return 1; }
    elif [[ "$out" == *ResourceNotFoundException* ]]; then
      printf '{}'
    else
      echo "secretsmanager read failed for mountos/$1: $out" >&2
      return 1
    fi
  }
  kv_put() {
    local name="mountos/$1"
    # --secret-string file:///dev/stdin keeps the payload out of argv (ps-visible).
    if aws secretsmanager describe-secret --region "$SM_REGION" --secret-id "$name" >/dev/null 2>&1; then
      aws secretsmanager put-secret-value --region "$SM_REGION" --secret-id "$name" \
        --secret-string file:///dev/stdin >/dev/null
    else
      aws secretsmanager create-secret --region "$SM_REGION" --name "$name" \
        --secret-string file:///dev/stdin >/dev/null
    fi
  }
  ;;
gcp)
  : "${VAULT_GCP_PROJECT_ID:?set VAULT_GCP_PROJECT_ID}"
  # See the aws kv_get note: {} ONLY on genuine not-found.
  kv_get() {
    local out
    if out="$(gcloud secrets versions access latest --secret="mountos__${1//\//__}" \
      --project="$VAULT_GCP_PROJECT_ID" 2>&1)"; then
      jq -c . <<<"$out" 2>/dev/null || { echo "mountos__${1//\//__} holds non-JSON content" >&2; return 1; }
    elif [[ "$out" == *NOT_FOUND* || "$out" == *"not found"* ]]; then
      printf '{}'
    else
      echo "secret manager read failed for mountos__${1//\//__}: $out" >&2
      return 1
    fi
  }
  kv_put() {
    local name="mountos__${1//\//__}"
    gcloud secrets describe "$name" --project="$VAULT_GCP_PROJECT_ID" >/dev/null 2>&1 \
      || gcloud secrets create "$name" --replication-policy=automatic --project="$VAULT_GCP_PROJECT_ID" >/dev/null
    gcloud secrets versions add "$name" --data-file=- --project="$VAULT_GCP_PROJECT_ID" >/dev/null
  }
  ;;
azure)
  : "${VAULT_AZURE_URL:?set VAULT_AZURE_URL (terraform output hub_key_vault_url)}"
  # See the aws kv_get note: {} ONLY on genuine not-found.
  kv_get() {
    local out
    if out="$(az keyvault secret show --id "${VAULT_AZURE_URL%/}/secrets/mountos--${1//\//--}" \
      --query value -o tsv 2>&1)"; then
      jq -c . <<<"$out" 2>/dev/null || { echo "mountos--${1//\//--} holds non-JSON content" >&2; return 1; }
    elif [[ "$out" == *SecretNotFound* ]]; then
      printf '{}'
    else
      echo "key vault read failed for mountos--${1//\//--}: $out" >&2
      return 1
    fi
  }
  kv_put() {
    # --file keeps the payload out of argv (ps-visible).
    az keyvault secret set --vault-name "$(sed -E 's#https://([^./]+)\..*#\1#' <<<"$VAULT_AZURE_URL")" \
      --name "mountos--${1//\//--}" --file <(cat) --encoding utf-8 >/dev/null
  }
  ;;
*)
  echo "unknown VAULT_PROVIDER '$VAULT_PROVIDER' (aws | hashicorp | gcp | azure)" >&2
  exit 1
  ;;
esac

if [[ "$VAULT_PROVIDER" == "hashicorp" ]]; then
  echo "==> enable KVv2 + AppRole (idempotent; re-runs get 'path already in use', hence || true)"
  v -X POST "$VAULT_ADDR/v1/sys/mounts/mountos" -d '{"type":"kv","options":{"version":"2"}}' >/dev/null || true
  v -X POST "$VAULT_ADDR/v1/sys/auth/approle"   -d '{"type":"approle"}' >/dev/null || true
  v -X PUT  "$VAULT_ADDR/v1/sys/policies/acl/appserv" \
    -d "$(jq -n '{policy:"path \"mountos/data/*\" { capabilities=[\"read\"] }"}')" >/dev/null \
    || { echo "vault policy write failed (check VAULT_TOKEN capabilities + VAULT_ADDR/VAULT_CACERT)" >&2; exit 1; }
fi

echo "==> write secrets (appserv config, service-verifiers)"
# Env, not --arg/--argjson: DB_URL and the signing key are real secrets and
# would otherwise sit in this process's argv (ps-visible to other local
# users for the subprocess's lifetime).
# ADMIN_DB_PROVIDER refines the dialect for byo managed engines (e.g.
# aurora-postgresql, alloydb, cockroachdb); it defaults to the dialect itself.
DB_DIALECT="$ADMIN_DB_DIALECT" DB_PROV="${ADMIN_DB_PROVIDER:-$ADMIN_DB_DIALECT}" \
  DB_URL="$ADMIN_DB_URL" DB_VER="${ADMIN_DB_PROVIDER_VERSION:?set ADMIN_DB_PROVIDER_VERSION in answers.env}" \
  SIGN_KEY="$(sec appserv_signing)" VERIFY_KEY="$(sec appserv_verification)" \
  PUB_KEY="$(sec admin_public)" HMAC_KEY="$(sec dashboard_hmac)" \
  jq -n '{DB_DIALECT:env.DB_DIALECT,DB_PROVIDER:env.DB_PROV,DB_URL:env.DB_URL,DB_PROVIDER_VERSION:env.DB_VER,
          ED25519_SIGNING_KEY:env.SIGN_KEY,ED25519_VERIFICATION_KEY:env.VERIFY_KEY,
          PROVIDER_VERIFICATION_KEY:env.PUB_KEY,DASHBOARD_USER_HMAC_KEY:env.HMAC_KEY}' \
  | kv_put appserv
# MERGE so a region fan-out (which adds dataserv/gcserv verifiers) is not wiped on re-seed.
existing_v="$(kv_get service-verifiers)"
[[ -n "$existing_v" ]] || { echo "service-verifiers read failed" >&2; exit 1; }
VERIFY_KEY="$(sec appserv_verification)" jq -n --argjson cur "$existing_v" \
  '$cur + {appserv: env.VERIFY_KEY}' \
  | kv_put service-verifiers
# api-master is NOT seeded here: it is a region-only secret (independent per
# region, appserv has no access to it per the permission matrix) — see
# bootstrap/region-seed.sh.

if [[ "$VAULT_PROVIDER" == "hashicorp" ]]; then
  echo "==> appserv AppRole"
  v -X POST "$VAULT_ADDR/v1/auth/approle/role/appserv" -d '{"token_policies":"appserv","token_ttl":"1h"}' >/dev/null
  role_id="$(v "$VAULT_ADDR/v1/auth/approle/role/appserv/role-id" | jq -r .data.role_id)"
  echo "role_id=$role_id"
  echo "  -> set this as a Terraform var; deliver the secret_id to instances via Vault"
  echo "     response-wrapping at launch (single-use, short-TTL). Do NOT bake a raw secret_id into the AMI/template."
else
  echo "==> done. Instances read the store with their platform identity (no AppRole/token to distribute)."
fi
