#!/bin/sh
# Entrypoint of the kvrocks container: renders the config, picks this pod's role, starts Kvrocks.
#
# The role is decided here on every container start. It must never come from the ConfigMap or
# from command-line flags: both would override what Sentinel decided at the last failover.
set -eu
SCRIPT_NAME=kvrocks-start
# shellcheck source=common.sh
. /scripts/common.sh

POLL_SECONDS=2

fail() {
  log "ERROR: $*"
  exit 1
}

# The password travels through an inline Redis command in the HAProxy health checks,
# where whitespace splits arguments and quotes open a string, and through quoted values in
# both config files.
validate_password() {
  case "${KVROCKS_PASSWORD:-}" in
    *[[:space:]\"\'\\]*) fail "the password must not contain whitespace, quotes or backslashes" ;;
  esac
}

render_config() {
  mkdir -p "$(dirname "$KVROCKS_CONF")"
  (
    umask 077
    {
      cat /etc/kvrocks/kvrocks.conf
      # Replicas are announced by name: pod IPs change on every restart.
      printf 'replica-announce-ip %s\n' "$(self_fqdn)"
      printf 'replica-announce-port %s\n' "$KVROCKS_PORT"
      if [ -n "${KVROCKS_PASSWORD:-}" ]; then
        # Quoted: an unquoted value is cut at the first '#'.
        printf 'requirepass "%s"\n' "$KVROCKS_PASSWORD"
        printf 'masterauth "%s"\n' "$KVROCKS_PASSWORD"
      fi
    } >"$KVROCKS_CONF.tmp"
  )
  mv "$KVROCKS_CONF.tmp" "$KVROCKS_CONF"
}

has_data() { # true once Kvrocks has opened its database on this volume at least once
  [ -f "$DATA_DIR/db/CURRENT" ]
}

# Who the master is, as far as anyone knows. Between this pod's saved view and its peers'
# Sentinels, the higher config epoch wins: a Sentinel that slept through a failover still
# names the old master, and following it would replace newer data with an older copy.
known_master() {
  local peers saved
  peers=$(newest_peer_view)
  saved=$(saved_view)
  if [ -n "$saved" ] && { [ -z "$peers" ] || [ "$(view_epoch "$saved")" -gt "$(view_epoch "$peers")" ]; }; then
    log "last master this pod knew (config epoch $(view_epoch "$saved")): $(view_master "$saved")"
    view_master "$saved"
  elif [ -n "$peers" ]; then
    log "master according to the peer Sentinels (config epoch $(view_epoch "$peers")): $(view_master "$peers")"
    view_master "$peers"
  fi
}

find_master() {
  local master
  master=$(known_master)
  if [ -z "$master" ]; then
    master=$(master_from_peer_kvrocks)
    [ -z "$master" ] || log "no Sentinel knows a master; $master reports itself as one"
  fi
  if [ -z "$master" ]; then
    # Nobody knows anything: a first install. Pod 0 is the first master.
    master=$(pod_fqdn 0)
    log "no master known anywhere; the first one is $master"
  fi
  printf '%s\n' "$master"
}

all_peers_are_empty_replicas() {
  local host
  for host in $(peer_fqdns); do
    [ "$(kv_info_field "$host" role)" = "slave" ] || return 1
    [ "$(kv_info_field "$host" master_repl_offset)" = "0" ] || return 1
  done
}

# This pod is to be the master but its volume is empty. That is right on a first install,
# and only then: every peer is an empty replica too. Otherwise this pod lost its disk, and
# starting as an empty master would make the peers that hold the data copy that emptiness.
# It then stays down until Sentinel has failed over to one of them.
wait_until_empty_start_is_safe() { # prints the master to follow, possibly this pod
  local master
  while true; do
    if all_peers_are_empty_replicas; then
      self_fqdn
      return 0
    fi
    master=$(master_from_peer_sentinels)
    if [ -n "$master" ] && [ "$master" != "$(self_fqdn)" ]; then
      printf '%s\n' "$master"
      return 0
    fi
    log "empty volume: waiting for every peer to start empty, or for a failover to a peer that holds the data"
    sleep "$POLL_SECONDS"
  done
}

# Data with no sentinel.conf next to it: Kvrocks ran on this volume, no Sentinel of the chart
# ever did. It was restored from a backup, or migrated from a standalone Kvrocks. Its write-ahead
# log holds every message the old master published, the hellos of the old Sentinels among them,
# and an empty replica resumes from the first sequence when the log still has it: replaying,
# it publishes those hellos again. The new Sentinels, at epoch 0, take them for news and follow
# failovers long gone, demoting this pod. Without that history, the replicas copy the data.
#
# The history is in two places: the archive, and the live log that RocksDB replays when it
# opens the database, then archives. Archiving stays off until Kvrocks restarts, so that the
# replayed log is deleted instead; meanwhile, a replica that falls behind the live log copies
# the data again rather than resuming.
drop_log_history_of_a_restored_volume() {
  has_data || return 0
  [ ! -f "$SENTINEL_CONF" ] || return 0
  log "data but no sentinel.conf, a restored volume: dropping its log history, the replicas will copy the data"
  rm -rf "$DATA_DIR/db/archive"
  printf 'rocksdb.wal_ttl_seconds 0\nrocksdb.wal_size_limit_mb 0\n' >>"$KVROCKS_CONF"
}

validate_password
render_config

if [ "$KVROCKS_ARCHITECTURE" = "replication" ]; then
  drop_log_history_of_a_restored_volume
  master=$(find_master)
  if [ "$master" = "$(self_fqdn)" ] && ! has_data; then
    master=$(wait_until_empty_start_is_safe)
  fi
  if [ "$master" = "$(self_fqdn)" ]; then
    log "starting as master"
  else
    log "starting as replica of $master"
    printf 'slaveof %s %s\n' "$master" "$KVROCKS_PORT" >>"$KVROCKS_CONF"
  fi
fi

exec kvrocks -c "$KVROCKS_CONF"
