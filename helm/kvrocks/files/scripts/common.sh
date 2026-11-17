#!/bin/sh
# Helpers shared by the kvrocks and sentinel containers. Sourced, never executed.
# POSIX sh plus `local`: runs under dash (kvrocks image) and busybox ash (sentinel image).
# shellcheck disable=SC2034  # the paths below are used by the scripts that source this file

DATA_DIR=/var/lib/kvrocks
KVROCKS_CONF="$DATA_DIR/conf/kvrocks.conf"
SENTINEL_CONF="$DATA_DIR/sentinel/sentinel.conf"
CLI_TIMEOUT_SECONDS=3

# redis-cli reads the password from this variable, which keeps it out of process arguments.
if [ -n "${KVROCKS_PASSWORD:-}" ]; then
  export REDISCLI_AUTH="$KVROCKS_PASSWORD"
fi

log() {
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SCRIPT_NAME:-kvrocks}" "$*" >&2
}

now_ms() {
  date +%s%3N
}

pod_fqdn() { # $1: pod ordinal
  printf '%s-%s.%s\n' "$KVROCKS_STATEFULSET" "$1" "$KVROCKS_PEERS_DOMAIN"
}

self_fqdn() {
  printf '%s.%s\n' "$POD_NAME" "$KVROCKS_PEERS_DOMAIN"
}

all_fqdns() {
  local ordinal=0
  while [ "$ordinal" -lt "$KVROCKS_REPLICAS" ]; do
    pod_fqdn "$ordinal"
    ordinal=$((ordinal + 1))
  done
}

peer_fqdns() {
  all_fqdns | grep -v -x -F "$(self_fqdn)" || true
}

is_cluster_pod() { # $1: hostname
  all_fqdns | grep -q -x -F "$1"
}

kv_cli() { # $1: host, then a Kvrocks command
  local host="$1"
  shift
  # MALLOC_CONF is meant for the kvrocks server; redis-cli only complains about it.
  MALLOC_CONF='' timeout "$CLI_TIMEOUT_SECONDS" \
    redis-cli -h "$host" -p "$KVROCKS_PORT" "$@" 2>/dev/null
}

sentinel_cli() { # $1: host, then a Sentinel command
  local host="$1"
  shift
  MALLOC_CONF='' timeout "$CLI_TIMEOUT_SECONDS" \
    redis-cli -h "$host" -p "$SENTINEL_PORT" "$@" 2>/dev/null
}

kv_info_field() { # $1: host, $2: field of INFO replication
  kv_cli "$1" info replication | tr -d '\r' |
    awk -F: -v field="$2" '$1 == field { print $2 }'
}

# The role of a Kvrocks: master, slave, or unknown when it does not answer. A script that
# took "no answer" for "not master" would skip the step that keeps data safe.
kv_role() { # $1: host
  local role
  role=$(kv_info_field "$1" role)
  case "$role" in
    master | slave) printf '%s\n' "$role" ;;
    *) printf 'unknown\n' ;;
  esac
}

# Two scripts pause the writes of this Kvrocks: the handover and the fencing sidecar. CLIENT
# UNPAUSE lifts every pause at once, so each one writes down until when it wants writes
# paused, and none lifts a pause another still holds. The directory is on the `tmp` volume,
# which the kvrocks and fence containers share.
WRITE_HOLDS_DIR=${WRITE_HOLDS_DIR:-/tmp/write-holds}

# Pauses writes on behalf of $1. Prints the reply of Kvrocks: OK once paused.
hold_writes() { # $1: holder (handover, fencing), $2: milliseconds
  mkdir -p "$WRITE_HOLDS_DIR"
  # Written before the pause: the other holder must never see a pause it cannot account for.
  # And through a rename, so that it never reads a half-written file.
  printf '%s\n' "$(($(now_ms) + $2))" >"$WRITE_HOLDS_DIR/.$1"
  mv "$WRITE_HOLDS_DIR/.$1" "$WRITE_HOLDS_DIR/$1"
  kv_cli localhost client pause "$2" write | tr -d '\r'
}

# Lets go of the writes $1 held. They resume, unless another holder still wants them paused:
# then fails, and prints that holder.
release_hold() { # $1: holder
  local hold until
  rm -f "$WRITE_HOLDS_DIR/$1"
  for hold in "$WRITE_HOLDS_DIR"/*; do
    [ -f "$hold" ] || continue
    until=$(cat "$hold")
    case "$until" in
      "" | *[!0-9]*) continue ;;
    esac
    if [ "$(now_ms)" -lt "$until" ]; then
      basename "$hold"
      return 1
    fi
  done
  kv_cli localhost client unpause >/dev/null || true
}

# A view is what a Sentinel believes: "<config epoch> <master>". Sentinel raises the epoch
# at every failover, so between two views the higher epoch is the more recent truth.
view_epoch() { # $1: view
  printf '%s\n' "${1%% *}"
}

view_master() { # $1: view
  printf '%s\n' "${1#* }"
}

# Prints the view only if it names one of our pods: an error reply (NOAUTH, unknown
# master name) or a pod removed by a scale-down must not be followed.
valid_view() { # $1: view, possibly empty
  if [ -n "$1" ] && is_cluster_pod "$(view_master "$1")"; then
    printf '%s\n' "$1"
  fi
}

sentinel_epoch() { # $1: Sentinel host
  sentinel_cli "$1" sentinel master "$SENTINEL_MASTER_NAME" | tr -d '\r' | paste - - |
    awk '$1 == "config-epoch" { print $2 + 0 }'
}

# The master comes from get-master-addr-by-name, not from the ip of SENTINEL MASTER: during
# a failover the leader raises the epoch when the replica is promoted, but only changes that
# ip at the very end. The epoch is read before and after, so that a failover completing in
# between cannot pair an old master with a new epoch.
sentinel_view() { # $1: Sentinel host
  local before master after
  before=$(sentinel_epoch "$1")
  master=$(sentinel_cli "$1" sentinel get-master-addr-by-name "$SENTINEL_MASTER_NAME" |
    head -n 1 | tr -d '\r')
  after=$(sentinel_epoch "$1")
  if [ -n "$before" ] && [ "$before" = "$after" ]; then
    valid_view "$before $master"
  fi
}

# The most recent view among the peer Sentinels. Peers only: the local Sentinel may be
# starting up, and its own knowledge is read from its config file instead (saved_view).
newest_peer_view() {
  local host
  for host in $(peer_fqdns); do
    sentinel_view "$host"
  done | sort -k1,1nr -k2,2 | head -n 1
}

# The view this pod's Sentinel last held. It lives on the data volume, so it survives a
# restart of the whole cluster, when no Sentinel is left to ask.
saved_view() {
  local view
  [ -f "$SENTINEL_CONF" ] || return 0
  view=$(awk -v name="$SENTINEL_MASTER_NAME" '
    $1 == "sentinel" && $2 == "monitor" && $3 == name { master = $4 }
    $1 == "sentinel" && $2 == "config-epoch" && $3 == name { epoch = $4 }
    END { if (master != "") print epoch + 0, master }' "$SENTINEL_CONF")
  valid_view "$view"
}

sentinel_master() { # $1: Sentinel host. Prints the master it names.
  local view
  view=$(sentinel_view "$1")
  [ -z "$view" ] || view_master "$view"
}

master_from_peer_sentinels() {
  local view
  view=$(newest_peer_view)
  [ -z "$view" ] || view_master "$view"
}

master_from_peer_kvrocks() { # a peer that reports itself as master
  local host
  for host in $(peer_fqdns); do
    if [ "$(kv_info_field "$host" role)" = "master" ]; then
      printf '%s\n' "$host"
      return 0
    fi
  done
}

# Sentinel leaves out of a failover a replica that has not answered its pings for this long.
SENTINEL_CANDIDATE_PING_MS=5000

# The replicas a Sentinel could promote, as it filters them: not down, not disconnected,
# answering pings, priority above 0. After a restart, a replica stays out for a while:
# Sentinel needs a DNS answer with the new address of its pod to reach it again.
promotable_replicas() { # $1: Sentinel host
  sentinel_cli "$1" sentinel replicas "$SENTINEL_MASTER_NAME" | promotable_replicas_from_reply
}

promotable_replicas_from_reply() { # reads the reply of SENTINEL REPLICAS
  tr -d '\r' | paste - - |
    awk -F '\t' -v max_ping_ms="$SENTINEL_CANDIDATE_PING_MS" '
      function emit() {
        if (host != "" && flags !~ /s_down|o_down|disconnected/ && priority != 0 && ping <= max_ping_ms)
          print host
      }
      $1 == "name" { emit(); host = ""; flags = ""; priority = 1; ping = 0 }
      $1 == "ip" { host = $2 }
      $1 == "flags" { flags = $2 }
      $1 == "slave-priority" || $1 == "replica-priority" { priority = $2 + 0 }
      $1 == "last-ok-ping-reply" { ping = $2 + 0 }
      END { emit() }' | sort -u
}
