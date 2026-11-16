#!/bin/sh
# Entrypoint of the sentinel container.
#
# sentinel.conf lives on the data volume and is rebuilt on every start: the settings come
# from the chart, the state (epochs, known replicas and Sentinels) from the previous file.
set -eu
SCRIPT_NAME=sentinel-start
# shellcheck source=common.sh
. /scripts/common.sh

POLL_SECONDS=1

# With no saved state, monitor whatever the Kvrocks next to this Sentinel follows:
# the kvrocks container already decided, and both must agree.
master_from_local_kvrocks() {
  case "$(kv_info_field localhost role)" in
    master) self_fqdn ;;
    slave) kv_info_field localhost master_host ;;
  esac
}

find_master_to_monitor() {
  local master
  while true; do
    master=$(saved_view)
    [ -z "$master" ] || master=$(view_master "$master")
    [ -n "$master" ] || master=$(master_from_peer_sentinels)
    [ -n "$master" ] || master=$(master_from_local_kvrocks)
    if [ -n "$master" ]; then
      printf '%s\n' "$master"
      return 0
    fi
    log "no master known yet, waiting for the local Kvrocks"
    sleep "$POLL_SECONDS"
  done
}

# Derived from the pod's name, so that a Sentinel that lost its volume comes back as the
# same voter. With a random ID it would be a new voter at the address of the one it
# replaces, and Sentinels end up counting one that no longer exists.
sentinel_id() {
  printf '%s' "$(self_fqdn)" | sha1sum | cut -c1-40
}

# Known replicas and Sentinels are kept only for pods that still exist, so that scaling
# down does not leave voters that can never answer.
saved_state() { # $1: previous sentinel.conf
  awk -v name="$SENTINEL_MASTER_NAME" -v pods="$(all_fqdns | tr '\n' ' ')" '
    BEGIN { split(pods, list, " "); for (i in list) is_pod[list[i]] = 1 }
    $1 != "sentinel" { next }
    $2 == "current-epoch" { print; next }
    $3 != name { next }
    $2 == "config-epoch" || $2 == "leader-epoch" { print; next }
    ($2 == "known-replica" || $2 == "known-sentinel") && is_pod[$4] { print }
  ' "$1"
}

write_conf() { # $1: master to monitor
  local previous="$SENTINEL_CONF.previous"
  if [ -f "$SENTINEL_CONF" ]; then
    cp "$SENTINEL_CONF" "$previous"
  else
    : >"$previous"
  fi
  (
    umask 077
    {
      printf 'port %s\n' "$SENTINEL_PORT"
      printf 'dir /tmp\n'
      printf 'protected-mode no\n'
      # Everything goes by hostname: pod IPs change on every restart.
      printf 'sentinel resolve-hostnames yes\n'
      printf 'sentinel announce-hostnames yes\n'
      printf 'sentinel announce-ip %s\n' "$(self_fqdn)"
      printf 'sentinel announce-port %s\n' "$SENTINEL_PORT"
      if [ -n "${KVROCKS_PASSWORD:-}" ]; then
        printf 'requirepass "%s"\n' "$KVROCKS_PASSWORD"
        printf 'sentinel sentinel-pass "%s"\n' "$KVROCKS_PASSWORD"
      fi
      printf 'sentinel myid %s\n' "$(sentinel_id)"
      printf 'sentinel monitor %s %s %s %s\n' \
        "$SENTINEL_MASTER_NAME" "$1" "$KVROCKS_PORT" "$SENTINEL_QUORUM"
      if [ -n "${KVROCKS_PASSWORD:-}" ]; then
        printf 'sentinel auth-pass %s "%s"\n' "$SENTINEL_MASTER_NAME" "$KVROCKS_PASSWORD"
      fi
      printf 'sentinel down-after-milliseconds %s %s\n' \
        "$SENTINEL_MASTER_NAME" "$SENTINEL_DOWN_AFTER_MS"
      printf 'sentinel failover-timeout %s %s\n' \
        "$SENTINEL_MASTER_NAME" "$SENTINEL_FAILOVER_TIMEOUT_MS"
      printf 'sentinel parallel-syncs %s %s\n' \
        "$SENTINEL_MASTER_NAME" "$SENTINEL_PARALLEL_SYNCS"
      printf 'sentinel client-reconfig-script %s /scripts/sentinel-reconfig.sh\n' \
        "$SENTINEL_MASTER_NAME"
      saved_state "$previous"
    } >"$SENTINEL_CONF.tmp"
  )
  mv "$SENTINEL_CONF.tmp" "$SENTINEL_CONF"
}

mkdir -p "$(dirname "$SENTINEL_CONF")"
master=$(find_master_to_monitor)
write_conf "$master"
log "monitoring $master"

exec redis-sentinel "$SENTINEL_CONF"
