#!/usr/bin/env bash
# Redeploy the demo fleet's Go services from a mountos-servers git commit, bypassing the
# public mountos.sh/install release channel entirely.
#
# WHY THIS EXISTS
# terraform's cloud-init templates install services via mos_installer_sh / mos_version,
# which resolves to the latest PUBLIC RELEASE. During pre-release testing (this demo's
# whole purpose) the fleet needs to run ahead-of-release commits instead. A fresh instance
# from `terraform apply` -- including one added mid-session, like a new blockserv copyset
# member -- always boots on the stale release build; this script is the required follow-up
# any time that happens, not a one-off workaround. It:
#   1. builds the named services (linux-arm64) from a git ref in an isolated worktree,
#   2. relays each binary through the wasabi-stage bucket (SSM has no direct file transfer
#      and these instances have no SSH), presigned GET only, deleted after use,
#   3. swaps the binary + restarts the service on every matching running instance via SSM,
#   4. sha256-verifies the on-box binary against the local build before declaring success.
#
# Never used for the mount-test client (mount-client.tf's own cloud-init explicitly keeps
# credentials off SSM send-command; this script never touches that box's credentials, only
# its mountos binary, which carries none).
#
# Usage:
#   ./demo-redeploy.sh <git-ref> <service>[,<service>...]
#   ./demo-redeploy.sh HEAD appserv,dataserv,blockserv,mfuse
#
# Services: appserv, dataserv, blockserv, mfuse (mfuse redeploys mount-client only).
set -euo pipefail

REPO="/Users/princejohnwesley/Projects/Private/mountOS/mountos-servers"
AWS_PROFILE="${AWS_PROFILE:-mountos-demo}"
AWS_REGION="${AWS_REGION:-us-west-2}"
RELAY_PROFILE="${RELAY_PROFILE:-wasabi-stage}"
RELAY_ENDPOINT="${RELAY_ENDPOINT:-https://s3.ap-southeast-1.wasabisys.com}"
RELAY_BUCKET="${RELAY_BUCKET:-jason-jadon}"

REF="${1:?usage: demo-redeploy.sh <git-ref> <service>[,<service>...]}"
SERVICES="${2:?usage: demo-redeploy.sh <git-ref> <service>[,<service>...]}"

SHA="$(git -C "$REPO" rev-parse --short=9 "$REF")"
WORKTREE="/tmp/mos-demoredeploy-$SHA"

echo "[1/4] preparing worktree at $SHA"
if [ ! -d "$WORKTREE" ]; then
  git -C "$REPO" worktree add "$WORKTREE" "$REF" >/dev/null
fi

relay_upload() {
  local file="$1" key="$2"
  # unset AWS_REGION for these calls: an inherited/exported AWS_REGION (e.g.
  # us-west-2, set for the fleet's own aws ec2/ssm calls below) leaks into the
  # SigV4 credential scope and Wasabi rejects the mismatched-region signature
  # with a 400, even though --endpoint-url points at the right region already.
  AWS_REGION= aws s3api put-object --profile "$RELAY_PROFILE" --endpoint-url "$RELAY_ENDPOINT" \
    --bucket "$RELAY_BUCKET" --key "$key" --body "$file" >/dev/null
  AWS_REGION= aws s3 presign "s3://$RELAY_BUCKET/$key" --profile "$RELAY_PROFILE" \
    --endpoint-url "$RELAY_ENDPOINT" --expires-in 900
}

relay_cleanup() {
  local key="$1"
  aws s3 rm "s3://$RELAY_BUCKET/$key" --profile "$RELAY_PROFILE" --endpoint-url "$RELAY_ENDPOINT" >/dev/null 2>&1 || true
}

# instance_ids <name-glob> -> newline-separated running instance ids
instance_ids() {
  aws ec2 describe-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' '\n'
}

# deploy_binary <local-bin-path> <remote-svc-name> <systemd-unit> <instance-id>
deploy_binary() {
  local local_bin="$1" svc="$2" unit="$3" iid="$4"
  local sha key url cmd_id status
  sha="$(shasum -a 256 "$local_bin" | awk '{print $1}')"
  key="demoredeploy-$svc-$SHA-$(basename "$local_bin")-$iid"
  url="$(relay_upload "$local_bin" "$key")"
  local doc_file="/tmp/demoredeploy-doc-$$.json"
  URL="$url" SVC="$svc" UNIT="$unit" DOC_FILE="$doc_file" python3 -c "
import json, os
url, svc, unit = os.environ['URL'], os.environ['SVC'], os.environ['UNIT']
cmds = ['set -euo pipefail', f'curl -fsSL \'{url}\' -o /tmp/{svc}.new', f'chmod +x /tmp/{svc}.new']
if unit:
    # systemd-managed (appserv/dataserv/blockserv): stop before swap, restart after.
    cmds.append(f'systemctl stop {unit}')
cmds.append(f'mv -f /tmp/{svc}.new /usr/local/bin/{svc}')
if unit:
    cmds += [f'systemctl start {unit}', 'sleep 2']
# mfuse on the mount-test client: not a service, no daemon to restart -- just swap
# the binary. An operator's already-running mount keeps its own in-memory copy;
# only the NEXT 'mountos mount' picks up the new one.
cmds.append(f'sha256sum /usr/local/bin/{svc}')
json.dump({'commands': cmds}, open(os.environ['DOC_FILE'], 'w'))
" || { echo "  FAIL $iid ($svc): could not build command doc" >&2; return 1; }
  cmd_id="$(aws ssm send-command --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --instance-ids "$iid" --document-name AWS-RunShellScript \
    --parameters "file://$doc_file" \
    --query 'Command.CommandId' --output text)"
  rm -f "$doc_file"
  sleep 8
  status="$(aws ssm get-command-invocation --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" --query 'Status' --output text)"
  local tries=0
  while [ "$status" = "InProgress" ] && [ "$tries" -lt 6 ]; do
    sleep 5; tries=$((tries+1))
    status="$(aws ssm get-command-invocation --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      --command-id "$cmd_id" --instance-id "$iid" --query 'Status' --output text)"
  done
  local remote_sha
  remote_sha="$(aws ssm get-command-invocation --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$iid" --query 'StandardOutputContent' --output text | awk '{print $1}')"
  relay_cleanup "$key"
  if [ "$status" = "Success" ] && [ "$remote_sha" = "$sha" ]; then
    echo "  ok   $iid ($svc, sha256 verified)"
  else
    echo "  FAIL $iid ($svc): status=$status remote_sha=$remote_sha expected=$sha" >&2
    # Surface the actual on-box error immediately -- without this, a failure only
    # tells you THAT it failed, not WHY, and re-diagnosing means a second manual
    # SSM round trip every time (e.g. the "text file busy" swap-into-a-running-mount
    # failure this script hit before it switched cp -> mv).
    aws ssm get-command-invocation --profile "$AWS_PROFILE" --region "$AWS_REGION" \
      --command-id "$cmd_id" --instance-id "$iid" \
      --query '{StdOut:StandardOutputContent,StdErr:StandardErrorContent}' --output json >&2
    return 1
  fi
}

echo "[2/4] building: $SERVICES"
cd "$WORKTREE"
export PATH="/opt/homebrew/bin:$PATH"
set -a; source ~/.mountos_profile; set +a
IFS=',' read -ra SVC_LIST <<< "$SERVICES"
for svc in "${SVC_LIST[@]}"; do
  case "$svc" in
    appserv|dataserv)
      make sqlc-generate >/dev/null
      SKIP_CODEGEN=1 SERV_PROD_ARCHES=arm64 make "prod-$svc"
      ;;
    blockserv)
      SERV_PROD_ARCHES=arm64 make prod-blockserv
      ;;
    mfuse)
      make _prod-one SVC=mfuse CROSS=linux-arm64
      ;;
    *)
      echo "unknown service: $svc (want appserv|dataserv|blockserv|mfuse)" >&2; exit 1 ;;
  esac
done

echo "[3/4] deploying"
rc=0
for svc in "${SVC_LIST[@]}"; do
  case "$svc" in
    appserv)
      for iid in $(instance_ids "*appserv*"); do
        deploy_binary "$WORKTREE/bin/linux-arm64/appserv" appserv appserv "$iid" || rc=1
      done
      ;;
    dataserv)
      for iid in $(instance_ids "*dataserv*"); do
        deploy_binary "$WORKTREE/bin/linux-arm64/dataserv" dataserv dataserv "$iid" || rc=1
      done
      ;;
    blockserv)
      for iid in $(instance_ids "*blockserv*"); do
        deploy_binary "$WORKTREE/bin/linux-arm64/blockserv" blockserv blockserv "$iid" || rc=1
      done
      ;;
    mfuse)
      for iid in $(instance_ids "*mount-client*"); do
        deploy_binary "$WORKTREE/bin/linux-arm64/mountos" mountos "" "$iid" || rc=1
      done
      ;;
  esac
done

echo "[4/4] done (worktree kept at $WORKTREE for reuse; remove by hand when done with this commit)"
exit $rc
