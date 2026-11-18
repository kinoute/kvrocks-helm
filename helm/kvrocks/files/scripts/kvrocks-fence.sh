#!/bin/sh
# Sidecar that fences the master: it pauses client writes as long as nothing shows that the
# rest of the cluster still follows it.
#
# Kvrocks has no min-replicas-to-write. Without fencing, a master cut off from its peers
# keeps acknowledging writes on the connections already open to it, through an HAProxy
# that still reaches it, for as long as the partition lasts. Meanwhile a majority of
# Sentinels promotes another pod, and every one of those writes is lost when this pod
# rejoins as a replica. Fenced, it only loses what it took in before the missed checks.
#
# Only a master that the cluster followed once, then stopped following, is fenced. A master
# that was never followed has no client: HAProxy only routes to a pod a majority of
# Sentinels names. That is the case of a replica Sentinel is promoting, and fencing it would
# stall the failover itself: Sentinel's own messages to it would wait behind the pause.
#
# The rest of the cluster follows this master when a majority of Sentinels names it, or when
# enough replicas report a live link to it. The replicas matter during a cluster DNS outage:
# Sentinel resolves hostnames on the spot and stops answering for seconds at a time, while
# the replication links, already open, keep working. A master cut off from its peers loses
# both the Sentinels and the replicas.
#
# It only pauses and resumes writes and never changes a role: demoting this pod is left to
# Sentinel and sentinel-reconfig.sh, which know which of two views is the more recent.
set -u
SCRIPT_NAME=kvrocks-fence
# shellcheck source=common.sh
. /scripts/common.sh

CHECK_INTERVAL_SECONDS=0.5
# A Sentinel or a DNS lookup that does not answer within this time counts as lost.
PROBE_TIMEOUT_SECONDS=0.5
# How long a master may go without a majority before its writes are paused: a single slow
# answer must not stop a healthy master.
FENCE_AFTER_MS=2000
# A pause is renewed at every check while fenced, and must outlast the slowest of them, or
# writes go through in between. A check takes up to 8.5 s: every lookup and every peer that
# times out, then a Kvrocks that needs its whole CLI_TIMEOUT_SECONDS to give its role, and
# again to take the pause. A long pause costs nothing when the cluster follows this pod
# again, since it is then lifted at once. If this container dies, writes come back on
# their own when it runs out.
FENCE_PAUSE_MS=10000

fenced=no
# When the cluster last followed this pod as master; empty if never since it became one.
last_confirmed_ms=""
# "<fqdn> <address>" of each peer, as last resolved. The peers are reached by address: if
# cluster DNS goes down, a healthy master must still see its Sentinels, or it would fence
# itself while nothing else is wrong.
peer_addresses=""

resolve() { # $1: hostname. Prints its address, or nothing.
  timeout "$PROBE_TIMEOUT_SECONDS" getent hosts "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

# Keeps the last address of a peer that no longer resolves. All are looked up at the same
# time: during a DNS outage each lookup costs a full timeout, and one after the other they
# would slow the checks down with every pod added.
refresh_peer_addresses() {
  local fqdn
  peer_addresses=$(
    for fqdn in $(peer_fqdns); do
      (
        address=$(resolve "$fqdn")
        if [ -z "$address" ]; then
          address=$(printf '%s\n' "$peer_addresses" | awk -v fqdn="$fqdn" '$1 == fqdn { print $2 }')
        fi
        [ -z "$address" ] || printf '%s %s\n' "$fqdn" "$address"
      ) &
    done
    wait
  )
}

# One line per Sentinel that names this pod as master ("sentinel"), and per replica with a
# live link to it ("replica"), counting this pod's own Sentinel. All are asked at the same
# time: during a partition, each unreachable one costs a full timeout.
followers() {
  local address
  (
    CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
    [ "$(sentinel_master localhost)" = "$(self_fqdn)" ] && echo sentinel
  ) &
  for address in $(printf '%s' "$peer_addresses" | awk '{ print $2 }'); do
    (
      CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
      [ "$(sentinel_master "$address")" = "$(self_fqdn)" ] && echo sentinel
    ) &
    (
      CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
      info=$(kv_cli "$address" info replication | tr -d '\r')
      printf '%s\n' "$info" | grep -q -x "master_host:$(self_fqdn)" &&
        printf '%s\n' "$info" | grep -q -x "master_link_status:up" &&
        echo replica
    ) &
  done
  wait
}

# What the last check found, for the log line that tells why writes were paused.
sentinels_naming=0
replicas_following=0

# A majority of Sentinels names this pod, or a majority of pods replicates from it.
is_followed() {
  local answers
  answers=$(followers)
  sentinels_naming=$(printf '%s\n' "$answers" | grep -c -x sentinel || true)
  replicas_following=$(printf '%s\n' "$answers" | grep -c -x replica || true)
  [ "$sentinels_naming" -ge "$SENTINEL_MAJORITY" ] ||
    [ "$replicas_following" -ge $((SENTINEL_MAJORITY - 1)) ]
}

fence() {
  local reply
  reply=$(hold_writes fencing "$FENCE_PAUSE_MS")
  # redis-cli exits 0 on an error reply: only the reply tells a refused pause, from a
  # Kvrocks without CLIENT PAUSE WRITE for instance. No reply at all is a Kvrocks that does
  # not answer, which may have paused anyway. Either way, the next check pauses again.
  if [ -n "$reply" ] && [ "$reply" != OK ]; then
    log "WARNING: neither a majority of Sentinels nor of replicas follows this pod, and Kvrocks refused to pause writes: $reply"
    return 0
  fi
  if [ "$fenced" = no ]; then
    log "writes paused: $sentinels_naming of $KVROCKS_REPLICAS Sentinels name this pod as master and $replicas_following of $((KVROCKS_REPLICAS - 1)) replicas follow it, a majority of neither"
    fenced=yes
  fi
}

unfence() { # $1: why
  local holder
  [ "$fenced" = yes ] || return 0
  fenced=no
  if holder=$(release_hold fencing); then
    log "$1: writes resumed"
  else
    log "$1: writes stay paused, the $holder still holds them"
  fi
}

while true; do
  sleep "$CHECK_INTERVAL_SECONDS"
  refresh_peer_addresses
  case "$(kv_role localhost)" in
    slave)
      last_confirmed_ms=""
      unfence "this pod is no longer master"
      continue
      ;;
    unknown)
      # No answer is not a demotion: a fenced master stays fenced.
      if [ "$fenced" = yes ]; then
        fence
      fi
      continue
      ;;
  esac
  if is_followed; then
    last_confirmed_ms=$(now_ms)
    unfence "the cluster follows this pod as master again"
    continue
  fi
  if [ -z "$last_confirmed_ms" ]; then
    continue
  fi
  if [ $(($(now_ms) - last_confirmed_ms)) -ge "$FENCE_AFTER_MS" ]; then
    fence
  fi
done
