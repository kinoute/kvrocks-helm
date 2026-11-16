#!/bin/sh
# Hands the master role over to an up-to-date replica without losing acknowledged writes.
# Does nothing on a replica. Runs from the preStop hook; run it by hand before maintenance:
#   kubectl exec <pod> -c kvrocks -- /scripts/kvrocks-switchover.sh
#
# Why not a plain SENTINEL FAILOVER: Sentinel promotes a replica while the old master keeps
# accepting writes for several seconds, and those writes are discarded once it is demoted.
# So client writes are paused first, every replica Sentinel might promote is proven to hold
# every write, and the old master is demoted as soon as the switch is announced.
#
# The pause must stay shorter than Sentinel's down-after-milliseconds: a paused master
# stops answering Sentinel's own PUBLISH and would be declared down.
#
# With --stopping (the preStop hook), writes stay paused when the handover gives up. The
# pod is about to stop, and the failover that follows then promotes an up-to-date replica.
set -eu
SCRIPT_NAME=kvrocks-switchover
# shellcheck source=common.sh
. /scripts/common.sh

POLL_SECONDS=0.1
# A replica or a Sentinel that is gone must not eat the write pause.
PROBE_TIMEOUT_SECONDS=0.5
# The failover must be requested this long before the write pause expires.
REQUEST_MARGIN_MS=2500
# Sentinel answers a failover request at once, unless something blocks it for a moment.
FAILOVER_REQUEST_TIMEOUT_SECONDS=1
DEMOTE_ATTEMPTS=30

stopping=no
if [ "${1:-}" = "--stopping" ]; then
  stopping=yes
fi

now_ms() {
  date +%s%3N
}

# The replicas this Sentinel could promote. It ranks them with offsets it read up to ten
# seconds earlier, so any of them may win: every one must be up to date.
promotion_candidates() ( # $1: Sentinel host. A subshell: the timeout stays local.
  CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
  promotable_replicas "$1"
)

# The Sentinel that will run the failover: among those that name this pod as master, the
# one that could promote the most replicas.
pick_sentinel() {
  local host master count best="" best_count=0
  for host in localhost $(peer_fqdns); do
    master=$(
      CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
      sentinel_master "$host"
    )
    [ "$master" = "$(self_fqdn)" ] || continue
    count=$(promotion_candidates "$host" | wc -l)
    if [ -z "$best" ] || [ "$count" -gt "$best_count" ]; then
      best=$host
      best_count=$count
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# Read on the replica itself: the master's own `lag` field does not drop to 0 at rest,
# and WAIT is blocked by the write pause.
replica_has_offset() { # $1: replica host, $2: offset to reach
  local offset
  offset=$(
    CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
    kv_info_field "$1" slave_repl_offset
  )
  [ -n "$offset" ] && [ "$offset" -ge "$2" ]
}

all_caught_up() { # $1: offset to reach, $2: replica hosts
  local host
  for host in $2; do
    replica_has_offset "$host" "$1" || return 1
  done
}

wait_until_caught_up() { # $1: offset to reach, $2: replica hosts, $3: deadline
  while [ "$(now_ms)" -lt "$3" ]; do
    if all_caught_up "$1" "$2"; then
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  return 1
}

# Fails when this Kvrocks cannot pause writes: CLIENT PAUSE WRITE came with Kvrocks 2.16.0.
pause_writes() {
  [ "$(kv_cli localhost client pause "$SWITCHOVER_PAUSE_MS" write)" = "OK" ]
}

resume_writes() {
  kv_cli localhost client unpause >/dev/null || true
}

release_writes() {
  if [ "$stopping" = no ]; then
    resume_writes
  fi
}

# Sentinel has accepted the failover: a new master is on its way, however long it takes.
# Writes stay held all along, because any write accepted here from now on would be lost.
# Sentinel gives up after its failover timeout; only then is this pod still the master.
wait_for_new_master() { # prints the new master
  local master host deadline
  deadline=$(($(now_ms) + SENTINEL_FAILOVER_TIMEOUT_MS))
  while [ "$(now_ms)" -lt "$deadline" ]; do
    pause_writes || true
    for host in localhost $(peer_fqdns); do
      # Short timeouts: an unreachable Sentinel must not outlast the write pause.
      master=$(
        CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
        sentinel_master "$host"
      )
      if [ -n "$master" ] && [ "$master" != "$(self_fqdn)" ]; then
        printf '%s\n' "$master"
        return 0
      fi
    done
    sleep "$POLL_SECONDS"
  done
  return 1
}

# Fails if this pod is still master after a few seconds. Writes then stay paused until the
# pause expires; by then the fencing sidecar holds them, as the Sentinels name another pod.
demote_to() { # $1: new master
  local attempt=0
  until [ "$(kv_role localhost)" = "slave" ]; do
    if [ "$attempt" -ge "$DEMOTE_ATTEMPTS" ]; then
      return 1
    fi
    pause_writes || true
    kv_cli localhost slaveof "$1" "$KVROCKS_PORT" >/dev/null || true
    attempt=$((attempt + 1))
    sleep "$POLL_SECONDS"
  done
  # Clients blocked by the pause must reconnect to the new master, not write here.
  kv_cli localhost client kill type normal >/dev/null || true
  kv_cli localhost config rewrite >/dev/null || true
}

# After a request that got no answer: did Sentinel start the failover all the same?
# Succeeds if it did, or if it cannot tell: a failover running unseen would lose any write
# accepted here, so writes stay held. Fails only once the Sentinel answers that nothing
# started, which makes giving up safe.
failover_started() { # $1: Sentinel host, $2: deadline
  local status
  while [ "$(now_ms)" -lt "$2" ]; do
    pause_writes || true
    status=$(
      CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
      sentinel_cli "$1" sentinel master "$SENTINEL_MASTER_NAME" | tr -d '\r' | paste - - |
        awk -F '\t' '$1 == "ip" { master = $2 } $1 == "flags" { flags = $2 }
          END { if (master != "") print master, flags }'
    ) || true
    case "$status" in
      "") ;;
      "$(self_fqdn) "*failover_in_progress*) return 0 ;;
      "$(self_fqdn) "*) return 1 ;;
      *) return 0 ;;
    esac
    sleep "$POLL_SECONDS"
  done
  return 0
}

give_up() { # $1: why. The EXIT trap releases the writes, unless the pod is stopping.
  log "$1, giving up"
  if [ "$stopping" = yes ]; then
    log "writes stay paused until this pod stops"
  fi
  exit 1
}

case "$(kv_role localhost)" in
  slave)
    log "not the master, nothing to hand over"
    exit 0
    ;;
  unknown)
    log "the local Kvrocks does not answer, no handover"
    exit 1
    ;;
esac

if ! sentinel=$(pick_sentinel); then
  log "no Sentinel names this pod as master, nothing to hand over"
  exit 1
fi
candidates=$(promotion_candidates "$sentinel")
if [ -z "$candidates" ]; then
  log "Sentinel has no replica it could promote, nothing to hand over to"
  exit 1
fi

started=$(now_ms)
deadline=$((started + SWITCHOVER_PAUSE_MS - REQUEST_MARGIN_MS))
if ! pause_writes; then
  log "ERROR: this Kvrocks cannot pause writes (CLIENT PAUSE WRITE needs Kvrocks 2.16.0 or later), no handover"
  exit 1
fi
# Until Sentinel accepts the failover, giving up is safe: writes simply resume here.
trap release_writes EXIT
target_offset=$(kv_info_field localhost master_repl_offset)

if ! wait_until_caught_up "$target_offset" "$candidates" "$deadline"; then
  give_up "a replica Sentinel could promote did not reach offset $target_offset in time"
fi
# A replica that came back in the meantime is a candidate too.
candidates=$(promotion_candidates "$sentinel")
if [ -z "$candidates" ] || ! all_caught_up "$target_offset" "$candidates"; then
  give_up "the replicas Sentinel could promote changed, and one of them is behind"
fi

reply=$(
  CLI_TIMEOUT_SECONDS=$FAILOVER_REQUEST_TIMEOUT_SECONDS
  sentinel_cli "$sentinel" sentinel failover "$SENTINEL_MASTER_NAME"
) || true
case "$reply" in
  OK) ;;
  "")
    log "Sentinel did not answer the failover request in time"
    if ! failover_started "$sentinel" "$((started + SWITCHOVER_PAUSE_MS))"; then
      give_up "Sentinel did not start the failover"
    fi
    ;;
  *) give_up "Sentinel refused the failover: $reply" ;;
esac

# Past this point there is no giving up: see wait_for_new_master.
trap - EXIT
if ! new_master=$(wait_for_new_master); then
  log "Sentinel abandoned the failover, this pod stays master"
  release_writes
  exit 1
fi

if ! demote_to "$new_master"; then
  log "ERROR: $new_master is master but this pod did not step down; its writes stay paused"
  exit 1
fi
resume_writes
log "handed the master role over to $new_master at offset $target_offset"
