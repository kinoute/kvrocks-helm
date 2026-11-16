#!/bin/sh
# Probes of the kvrocks container. Usage: kvrocks-probe.sh startup|liveness|readiness
#
# They read INFO, never ROLE: ROLE crashes Kvrocks 2.17.0 during a full sync (apache/kvrocks#3666).
SCRIPT_NAME=kvrocks-probe
# shellcheck source=common.sh
. /scripts/common.sh

# Any reply counts, including an error such as "restoring the db from backup":
# killing a replica in the middle of a full sync would restart that sync forever.
answers() {
  [ -n "$(kv_cli localhost ping)" ]
}

# A Sentinel that does not answer within this time counts as one that cannot promote us.
SENTINEL_PROBE_TIMEOUT_SECONDS=0.5

# How many Sentinels could promote this replica right now.
promotable_by() {
  local host
  for host in localhost $(peer_fqdns); do
    (
      CLI_TIMEOUT_SECONDS=$SENTINEL_PROBE_TIMEOUT_SECONDS
      promotable_replicas "$host"
    ) &
  done | grep -c -x -F "$(self_fqdn)" || true
}

# A replica is ready once it follows its master, has finished syncing, and a majority of
# Sentinels could promote it. The rolling update waits for readiness, so it never stops the
# next pod, the master maybe, while this one is still catching up or out of Sentinel's reach.
is_ready() {
  case "$(kv_info_field localhost role)" in
    master) return 0 ;;
    slave)
      [ "$(kv_info_field localhost master_link_status)" = "up" ] &&
        [ "$(kv_info_field localhost master_sync_in_progress)" = "0" ] &&
        { [ "$KVROCKS_ARCHITECTURE" != "replication" ] || [ "$(promotable_by)" -ge "$SENTINEL_MAJORITY" ]; }
      ;;
    *) return 1 ;;
  esac
}

case "${1:-}" in
  startup | liveness) answers ;;
  readiness) is_ready ;;
  *)
    log "unknown probe: ${1:-}"
    exit 2
    ;;
esac
