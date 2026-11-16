#!/bin/sh
# Sidecar that fences the master: it pauses client writes as long as a majority of
# Sentinels does not confirm this pod as master.
#
# Kvrocks has no min-replicas-to-write. Without fencing, a master cut off from its peers
# keeps acknowledging writes on the connections already open to it, through an HAProxy
# that still reaches it, for as long as the partition lasts. Meanwhile a majority of
# Sentinels promotes another pod, and every one of those writes is lost when this pod
# rejoins as a replica. Fenced, it only loses what it took in before the missed checks.
#
# Only a master that a majority of Sentinels confirmed once, then stopped confirming, is
# fenced. A master that was never confirmed has no client: HAProxy only routes to a pod a
# majority names. That is the case of a replica Sentinel is promoting, and fencing it would
# stall the failover itself: Sentinel's own messages to it would wait behind the pause.
#
# It only pauses and resumes writes and never changes a role: demoting this pod is left to
# Sentinel and sentinel-reconfig.sh, which know which of two views is the more recent.
set -u
SCRIPT_NAME=kvrocks-fence
# shellcheck source=common.sh
. /scripts/common.sh

CHECK_INTERVAL_SECONDS=0.5
# A Sentinel that does not answer within this time counts as lost.
SENTINEL_PROBE_TIMEOUT_SECONDS=0.5
# How long a master may go without a majority before its writes are paused: a single slow
# answer must not stop a healthy master.
FENCE_AFTER_MS=2000
# Each pause outlasts a few checks and is renewed at every check while fenced. If this
# container dies, writes come back on their own.
FENCE_PAUSE_MS=3000

fenced=no
# When a majority of Sentinels last named this pod as master; empty if never since it became one.
last_confirmed_ms=""

now_ms() {
  date +%s%3N
}

# How many Sentinels, this pod's own included, name this pod as master right now. They are
# asked at the same time: during a partition, each unreachable one costs a full timeout.
confirming_sentinels() {
  local host
  for host in localhost $(peer_fqdns); do
    (
      CLI_TIMEOUT_SECONDS=$SENTINEL_PROBE_TIMEOUT_SECONDS
      sentinel_master "$host"
    ) &
  done | grep -c -x -F "$(self_fqdn)" || true
}

fence() {
  kv_cli localhost client pause "$FENCE_PAUSE_MS" write >/dev/null || true
  if [ "$fenced" = no ]; then
    log "no majority of Sentinels confirms this pod as master: writes paused"
    fenced=yes
  fi
}

unfence() { # $1: why
  [ "$fenced" = yes ] || return 0
  kv_cli localhost client unpause >/dev/null || true
  fenced=no
  log "$1: writes resumed"
}

while true; do
  sleep "$CHECK_INTERVAL_SECONDS"
  if [ "$(kv_info_field localhost role)" != "master" ]; then
    last_confirmed_ms=""
    unfence "this pod is no longer master"
    continue
  fi
  if [ "$(confirming_sentinels)" -ge "$SENTINEL_MAJORITY" ]; then
    last_confirmed_ms=$(now_ms)
    unfence "a majority of Sentinels confirms this pod as master again"
    continue
  fi
  if [ -z "$last_confirmed_ms" ]; then
    continue
  fi
  if [ $(($(now_ms) - last_confirmed_ms)) -ge "$FENCE_AFTER_MS" ]; then
    fence
  fi
done
