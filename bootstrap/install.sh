#!/usr/bin/env bash
# Per-instance bootstrap, invoked by cloud-init on each appserv EC2 instance.
# Idempotent and NON-DESTRUCTIVE. Inputs arrive via /etc/mountos/appserv.env
# (written by cloud-init from the launch template + IMDS + the unwrapped AppRole):
#   MOS_VERSION, VAULT_PROVIDER, VAULT_HASHICORP_ADDRESS,
#   VAULT_HASHICORP_ROLE_ID, VAULT_HASHICORP_SECRET_ID, PORT, ADVERTISE_ADDR.
set -euo pipefail
set -a; . /etc/mountos/appserv.env; set +a

echo "==> install appserv ${MOS_VERSION:-latest} from https://n.sh"
curl -fsSL https://n.sh | bash -s -- --pkg appserv ${MOS_VERSION:+--version "$MOS_VERSION"}

echo "==> db install (idempotent; the migration lock makes concurrent instances safe)"
/usr/local/bin/appserv db install

echo "==> enable + start appserv"
install -m 0644 /opt/mountos/appserv.service /etc/systemd/system/appserv.service
systemctl daemon-reload
systemctl enable --now appserv
