#!/usr/bin/env bash
# Copy the secrets blockserv reads from the hub's AWS Secrets Manager region
# store into the Key Vault of this root. Blockserv members run with
# VAULT_PROVIDER=azure, so they read the same logical paths from Key Vault:
#
#   mountos-<prefix>/blockserv            -> mountos-<prefix>--blockserv
#   mountos-<prefix>/service-verifiers    -> mountos-<prefix>--service-verifiers
#   mountos-<prefix>/s3creds/<storage id> -> mountos-<prefix>--s3creds--<storage id>
#
# s3creds exists once the block storage entry is created on the hub, so run this
# after step 3 in main.tf, once per storage id. Run it again after any rotation
# on the hub. Secret values go through 0600 temp files, never argv or stdout.
#
# usage: seed-keyvault.sh <key-vault-name> <resource-prefix> <storage-id> [<storage-id>...]
# env:   AWS_PROFILE and AWS_REGION select the hub store.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <key-vault-name> <resource-prefix> <storage-id> [<storage-id>...]" >&2
  exit 2
fi
kv="$1"; prefix="$2"; shift 2
root="mountos${prefix:+-$prefix}"

umask 077
tmp="$(mktemp -d)"
trap 'rm -f "$tmp"/secret; rmdir "$tmp"' EXIT

copy() { # $1 = source secret id, $2 = Key Vault secret name
  if ! aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text >"$tmp/secret"; then
    echo "read failed for hub secret $1 (check AWS_PROFILE, AWS_REGION and that the secret exists)" >&2
    exit 1
  fi
  [[ -s "$tmp/secret" ]] || { echo "hub secret $1 is empty" >&2; exit 1; }
  az keyvault secret set --vault-name "$kv" --name "$2" --file "$tmp/secret" --encoding utf-8 --output none
  echo "seeded $2 ($(wc -c <"$tmp/secret" | tr -d ' ') bytes)"
}

copy "$root/blockserv" "$root--blockserv"
copy "$root/service-verifiers" "$root--service-verifiers"
for sid in "$@"; do
  copy "$root/s3creds/$sid" "$root--s3creds--$sid"
done
