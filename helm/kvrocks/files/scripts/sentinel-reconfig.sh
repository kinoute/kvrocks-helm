#!/bin/sh
# Sentinel runs this on every master change (client-reconfig-script):
#   <master-name> <role> <state> <from-host> <from-port> <to-host> <to-port>
#
# Sentinel itself only demotes the old master about ten seconds after the switch. Until then
# it still accepts writes, and they are discarded once it becomes a replica. The Sentinel
# that shares a pod with the old master demotes it right away instead.
#
# Exit status 1 makes Sentinel run the script again later (up to 10 times), so it is used
# whenever the demotion could not be confirmed. 0 means there is nothing left to do.
SCRIPT_NAME=sentinel-reconfig
# shellcheck source=common.sh
. /scripts/common.sh

# Sentinel kills a script that runs longer than 60 s. Shorter in the unit tests.
DEMOTE_TIMEOUT_SECONDS=${DEMOTE_TIMEOUT_SECONDS:-45}
RETRY_SECONDS=1

from_host=$4
to_host=$6
to_port=$7

[ "$from_host" = "$(self_fqdn)" ] || exit 0

deadline=$(($(date +%s) + DEMOTE_TIMEOUT_SECONDS))
attempt=1
while true; do
  case "$(kv_role localhost)" in
    slave)
      [ "$attempt" -eq 1 ] || log "the local Kvrocks now follows $to_host"
      exit 0
      ;;
    master)
      [ "$attempt" -gt 1 ] || log "demoting the local Kvrocks, new master is $to_host"
      kv_cli localhost slaveof "$to_host" "$to_port" >/dev/null || true
      # Connected clients must reconnect and reach the new master.
      kv_cli localhost client kill type normal >/dev/null || true
      kv_cli localhost config rewrite >/dev/null || true
      ;;
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "could not confirm the demotion of the local Kvrocks, Sentinel will run this again"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep "$RETRY_SECONDS"
done
