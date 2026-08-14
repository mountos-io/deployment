#!/usr/bin/env bash
# Staged blockserv rollout, one member at a time.
#
# WHY THIS EXISTS
# A block storage is an active-active mesh of 1 to 3 members that share one
# block-storage group. A plain `terraform apply` replaces every member that
# changed in the SAME apply, so a template change (a MOS_VERSION bump, an edit
# to the cloud-init template, setting resource_prefix) takes the whole mesh
# down together and the storage stops serving. With 3 members that is a
# self-inflicted outage of an HA group that was specifically built not to have
# one.
#
# This applies the SAME converged configuration, but member by member, so at
# most one member is down at a time and the rest keep serving. It is the same
# idea as a rolling instance refresh on the dataserv fleet, which the instance
# group does for you; a per-member VM has no equivalent, so it is done here.
#
# Terraform cannot express this on its own: a dependency chain between members
# still destroys all of them before creating any, and create_before_destroy
# cannot work while each member pins a static public IP that only one NIC can
# hold at a time.
#
# USAGE
#   ./block-roll.sh                 # roll every member, in order, with a health gate
#   ./block-roll.sh --dry-run       # show what would happen, change nothing
#   ./block-roll.sh --wait 180      # seconds to allow a member to come back (default 300)
#   CLOUD=gcp ./block-roll.sh       # pick the cloud, same as the Makefile
#
# Safe to re-run. A member already matching the desired configuration is a
# no-op for that member, so an interrupted roll resumes where it stopped.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD="${CLOUD:-$(sed -n 's/^CLOUD=\([a-zA-Z]*\).*$/\1/p' "$HERE/answers.env" 2>/dev/null || true)}"
CLOUD="${CLOUD:-aws}"
TF="$HERE/clouds/$CLOUD/terraform"

DRY_RUN=0
WAIT_SECS=300
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --wait) WAIT_SECS="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -d "$TF" ] || { echo "no terraform directory for CLOUD=$CLOUD at $TF" >&2; exit 1; }

# The per-member VM resource differs by cloud; the members map key is the
# block_volume_id in all three.
case "$CLOUD" in
  aws)   RESOURCE="aws_instance.blockserv" ;;
  gcp)   RESOURCE="google_compute_instance.blockserv" ;;
  azure) RESOURCE="azurerm_linux_virtual_machine.blockserv" ;;
  *) echo "unsupported CLOUD=$CLOUD" >&2; exit 1 ;;
esac

echo "cloud:     $CLOUD"
echo "resource:  $RESOURCE"
echo "state dir: $TF"
echo

# Read the member addresses straight from state, so the roll covers exactly
# what is deployed rather than what the tfvars currently say.
#
# A while-read loop rather than mapfile: macOS ships bash 3.2, where mapfile
# does not exist, and operators run this from their own machines.
MEMBERS=()
while IFS= read -r line; do
  [ -n "$line" ] && MEMBERS+=("$line")
done < <(terraform -chdir="$TF" state list 2>/dev/null | grep -E "^${RESOURCE}\[" || true)

if [ "${#MEMBERS[@]}" -eq 0 ]; then
  echo "No blockserv members in state. Nothing to roll."
  echo "(block_enable is false, or the mesh has not been applied yet.)"
  exit 0
fi

echo "Found ${#MEMBERS[@]} member(s):"
printf '  %s\n' "${MEMBERS[@]}"
echo

if [ "${#MEMBERS[@]}" -eq 1 ]; then
  echo "WARNING: a single-member block storage has no redundancy, so this roll"
  echo "         WILL interrupt service for that storage. Continuing anyway;"
  echo "         there is no ordering that avoids it with one member."
  echo
fi

for i in "${!MEMBERS[@]}"; do
  m="${MEMBERS[$i]}"
  n=$((i + 1))
  echo "=============================================================="
  echo "[$n/${#MEMBERS[@]}] $m"
  echo "=============================================================="

  if [ "$DRY_RUN" -eq 1 ]; then
    terraform -chdir="$TF" plan -var-file=terraform.tfvars -target="$m"
    echo "[dry-run] would apply the above, then wait for the member to return."
    echo
    continue
  fi

  # -target is normally a smell. Here it is the mechanism: it is what limits the
  # blast radius to one member per step.
  terraform -chdir="$TF" apply -var-file=terraform.tfvars -target="$m"

  if [ "$n" -lt "${#MEMBERS[@]}" ]; then
    echo
    echo "Member $n applied. Confirm it is serving again before the next one:"
    echo "  - the hub node list shows it healthy"
    echo "  - it has re-peered with the other members"
    echo

    if [ -t 0 ]; then
      # Interactive: the operator gates each step. A timeout stops the roll
      # rather than continuing, because an unattended roll is how you end up
      # taking down a second member while the first is still coming back.
      read -r -t "$WAIT_SECS" -p "Press Enter to roll the next member, or Ctrl-C to stop here: " _ || {
        echo
        echo "No input within ${WAIT_SECS}s. Stopping BEFORE the next member."
        echo "Re-run this script to continue; already-rolled members are no-ops."
        exit 0
      }
    else
      # Non-interactive (CI, nohup, a pipeline): there is nobody to confirm, so
      # settle for the full wait instead of prompting. Without this branch the
      # read fails instantly on a missing TTY and the roll stops after member 1.
      echo "Not a terminal, so waiting the full ${WAIT_SECS}s before the next member."
      echo "This is a timer, NOT a health check. Prefer an interactive run, or"
      echo "drive one member per invocation from your own orchestration."
      sleep "$WAIT_SECS"
    fi
    echo
  fi
done

echo
echo "All ${#MEMBERS[@]} member(s) rolled."
echo "Run a full 'make apply' afterwards: -target skips the rest of the graph, so"
echo "anything outside blockserv is still unconverged until you do."
