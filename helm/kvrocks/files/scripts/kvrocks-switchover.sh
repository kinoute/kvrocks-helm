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
#
# With --to <pod>, Sentinel promotes that replica: before a Kvrocks upgrade, the master moves
# to the pod the rolling update restarts last. Run it on the master.
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
# Time to renew the write pause once Sentinel has answered the request.
RENEWAL_MARGIN_MS=500
DEMOTE_ATTEMPTS=30
# Sentinel promotes the up-to-date replica with the lowest priority; the default is 100.
TARGET_PRIORITY=1
# Sentinel reads the priority of each replica from its INFO, every ten seconds.
PRIORITY_SEEN_TIMEOUT_SECONDS=${PRIORITY_SEEN_TIMEOUT_SECONDS:-15}
USAGE="usage: kvrocks-switchover.sh [--stopping] [--to <pod name>]"

stopping=no
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stopping) stopping=yes ;;
    --to)
      if [ $# -lt 2 ]; then
        log "$USAGE"
        exit 2
      fi
      target="$2.$KVROCKS_PEERS_DOMAIN"
      shift
      ;;
    *)
      log "$USAGE"
      exit 2
      ;;
  esac
  shift
done

# What the EXIT trap undoes: writes paused before Sentinel accepted the failover, and the
# priority given to the target.
writes_held=no
target_priority=""

# The replicas this Sentinel could promote. It ranks them with offsets it read up to ten
# seconds earlier, so any of them may win: every one must be up to date.
promotion_candidates() ( # $1: Sentinel host. A subshell: the timeout stays local.
  CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
  promotable_replicas "$1"
)

# Sentinel goes into TILT mode for 30 s after it was stalled for more than 2 s, by a busy
# node for instance. It still answers then, OK to a failover request too, but runs nothing.
sentinel_in_tilt() { # $1: Sentinel host
  local tilt
  tilt=$(
    CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
    sentinel_cli "$1" info sentinel | tr -d '\r' | sed -n 's/^sentinel_tilt://p'
  )
  [ "$tilt" = 1 ]
}

# The Sentinel that will run the failover: among those that name this pod as master, the
# one that could promote the most replicas. One in TILT mode would start the failover only
# when it leaves TILT, writes paused until then: it is picked only when all of them are.
pick_sentinel() {
  local host master count best="" best_count=0 tilted=""
  for host in localhost $(peer_fqdns); do
    master=$(
      CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
      sentinel_master "$host"
    )
    [ "$master" = "$(self_fqdn)" ] || continue
    if sentinel_in_tilt "$host"; then
      tilted=${tilted:-$host}
      continue
    fi
    count=$(promotion_candidates "$host" | wc -l)
    if [ -z "$best" ] || [ "$count" -gt "$best_count" ]; then
      best=$host
      best_count=$count
    fi
  done
  if [ -z "$best" ] && [ -n "$tilted" ]; then
    log "every Sentinel that names this pod as master is in TILT mode: writes stay paused until $tilted leaves it, up to 30 s"
    best=$tilted
  fi
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# The priority Sentinel last read from a replica.
sentinel_priority_of() { # $1: Sentinel host, $2: replica host
  (
    CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
    sentinel_cli "$1" sentinel replicas "$SENTINEL_MASTER_NAME"
  ) | tr -d '\r' | paste - - | awk -F '\t' -v replica="$2" '
    $1 == "ip" { host = $2 }
    ($1 == "slave-priority" || $1 == "replica-priority") && host == replica { print $2 }'
}

# Gives the target the lowest priority, and waits until the Sentinel that will run the
# failover has read it. Done before writes are paused: that can take ten seconds.
steer_to_target() {
  local deadline
  if ! printf '%s\n' "$candidates" | grep -q -x -F "$target"; then
    log "$target is not a replica Sentinel could promote, no handover"
    exit 1
  fi
  target_priority=$(kv_cli "$target" config get slave-priority | tr -d '\r' | sed -n 2p)
  if [ -z "$target_priority" ]; then
    log "cannot read the priority of $target, no handover"
    exit 1
  fi
  kv_cli "$target" config set slave-priority "$TARGET_PRIORITY" >/dev/null
  deadline=$(($(now_ms) + PRIORITY_SEEN_TIMEOUT_SECONDS * 1000))
  until [ "$(sentinel_priority_of "$sentinel" "$target")" = "$TARGET_PRIORITY" ]; do
    if [ "$(now_ms)" -ge "$deadline" ]; then
      log "Sentinel did not read the new priority of $target in time, no handover"
      exit 1
    fi
    sleep "$POLL_SECONDS"
  done
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
  [ "$(hold_writes handover "$SWITCHOVER_PAUSE_MS")" = "OK" ]
}

resume_writes() {
  local holder
  if ! holder=$(release_hold handover); then
    log "writes stay paused, the $holder still holds them"
  fi
}

release_writes() {
  if [ "$stopping" = no ]; then
    resume_writes
  fi
}

# Left with the lowest priority, the target would be promoted first at any failover, even
# far behind the others, until it restarts.
restore_target_priority() {
  if [ "$(kv_cli "$target" config set slave-priority "$target_priority")" != "OK" ]; then
    log "WARNING: could not give $target its priority $target_priority back: until it restarts, Sentinel promotes it first at any failover, even behind; run CONFIG SET slave-priority $target_priority on it, or restart it"
    return 0
  fi
  kv_cli "$target" config rewrite >/dev/null || true
}

cleanup() {
  # A second signal must not cut the cleanup short.
  trap '' INT TERM HUP PIPE
  if [ "$writes_held" = yes ]; then
    release_writes
  fi
  if [ -n "$target_priority" ]; then
    restore_target_priority
  fi
}

# Sentinel has accepted the failover: a new master is on its way, however long it takes.
# Writes stay held all along, because any write accepted here from now on would be lost.
# Sentinel gives up after its failover timeout; only then is this pod still the master.
# Only a view of a later epoch than the one before the request names the master this
# failover promotes: a Sentinel that missed earlier failovers may still name an older one.
wait_for_new_master() { # $1: config epoch before the request. Prints the new master.
  local view master host deadline
  deadline=$(($(now_ms) + SENTINEL_FAILOVER_TIMEOUT_MS))
  while [ "$(now_ms)" -lt "$deadline" ]; do
    pause_writes || true
    for host in localhost $(peer_fqdns); do
      # Short timeouts: an unreachable Sentinel must not outlast the write pause.
      view=$(
        CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
        sentinel_view "$host"
      )
      [ -n "$view" ] || continue
      [ "$(view_epoch "$view")" -gt "$1" ] || continue
      master=$(view_master "$view")
      if [ "$master" != "$(self_fqdn)" ]; then
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

trap cleanup EXIT
# Ctrl-C, a kill, or a kubectl session that is lost: until Sentinel accepts the failover,
# stopping is safe, and the EXIT trap gives back the writes and the target's priority.
trap 'exit 1' INT TERM HUP PIPE

case "$(kv_role localhost)" in
  slave)
    named=$(
      CLI_TIMEOUT_SECONDS=$PROBE_TIMEOUT_SECONDS
      sentinel_master localhost
    ) || true
    log "not the master, nothing to hand over (the Sentinel here names ${named:-no master})"
    exit 0
    ;;
  unknown)
    log "the local Kvrocks does not answer, no handover"
    exit 1
    ;;
esac

if [ "$target" = "$(self_fqdn)" ]; then
  log "already the master"
  exit 0
fi

if ! sentinel=$(pick_sentinel); then
  log "no Sentinel names this pod as master, nothing to hand over"
  exit 1
fi
epoch_before=$(sentinel_epoch "$sentinel")
if [ -z "$epoch_before" ]; then
  log "Sentinel does not give its config epoch, no handover"
  exit 1
fi
candidates=$(promotion_candidates "$sentinel")
if [ -z "$candidates" ]; then
  log "Sentinel has no replica it could promote, nothing to hand over to"
  exit 1
fi
if [ -n "$target" ]; then
  steer_to_target
fi

started=$(now_ms)
pause_ends=$((started + SWITCHOVER_PAUSE_MS))
deadline=$((pause_ends - REQUEST_MARGIN_MS))
# A write accepted once the pause runs out could miss the replica Sentinel promotes: the
# pause must outlast the request and the renewal that follows it.
latest_request=$((pause_ends - FAILOVER_REQUEST_TIMEOUT_SECONDS * 1000 - RENEWAL_MARGIN_MS))
# Until Sentinel accepts the failover, giving up is safe: writes simply resume here. Held
# before the pause is asked for: a signal that lands while Kvrocks takes it must release it
# all the same, and releasing a pause that never took changes nothing.
writes_held=yes
if ! pause_writes; then
  log "ERROR: this Kvrocks cannot pause writes (CLIENT PAUSE WRITE needs Kvrocks 2.16.0 or later), no handover"
  exit 1
fi
target_offset=$(kv_info_field localhost master_repl_offset)
if [ -z "$target_offset" ]; then
  give_up "cannot read the replication offset of this Kvrocks"
fi

if ! wait_until_caught_up "$target_offset" "$candidates" "$deadline"; then
  give_up "a replica Sentinel could promote did not reach offset $target_offset in time"
fi
# A replica that came back in the meantime is a candidate too.
candidates=$(promotion_candidates "$sentinel")
if [ -z "$candidates" ] || ! all_caught_up "$target_offset" "$candidates"; then
  give_up "the replicas Sentinel could promote changed, and one of them is behind"
fi
# Kvrocks only holds the commands flagged as writes, and another one may still write: the
# replicas were checked against the offset read when writes stopped, and no later.
if [ "$(kv_info_field localhost master_repl_offset)" != "$target_offset" ]; then
  give_up "this Kvrocks moved past offset $target_offset during the write pause"
fi
if [ "$(now_ms)" -ge "$latest_request" ]; then
  give_up "the checks took too long: the write pause would run out before Sentinel answers"
fi

reply=$(
  CLI_TIMEOUT_SECONDS=$FAILOVER_REQUEST_TIMEOUT_SECONDS
  sentinel_cli "$sentinel" sentinel failover "$SENTINEL_MASTER_NAME"
) || true
case "$reply" in
  OK) ;;
  # This Sentinel runs a failover of this master already: a new master is on its way too.
  INPROG*) log "Sentinel is failing this master over already" ;;
  "")
    log "Sentinel did not answer the failover request in time"
    if ! failover_started "$sentinel" "$pause_ends"; then
      give_up "Sentinel did not start the failover"
    fi
    ;;
  *) give_up "Sentinel refused the failover: $reply" ;;
esac

# Past this point there is no giving up: see wait_for_new_master. Nor any stopping on a
# signal: until this pod steps down, it would take writes the new master never gets.
writes_held=no
trap '' INT TERM HUP PIPE
if ! new_master=$(wait_for_new_master "$epoch_before"); then
  log "Sentinel abandoned the failover, this pod stays master"
  release_writes
  exit 1
fi

if ! demote_to "$new_master"; then
  log "ERROR: $new_master is master but this pod did not step down; its writes stay paused"
  exit 1
fi
# HAProxy still sends clients here for a few seconds: it stops routing new connections to this
# pod within a second, but closes the sessions already open only after `haproxy.check.fall`
# failed role checks. A write that ran here now would be refused as read-only, an error most
# clients do not retry, and redis-py keeps the connection after it: every write that follows
# fails too. Held, a write never runs: Kvrocks looks at the pause before the role, and HAProxy
# closes the session first. The client then reconnects to the new master. The pause runs out
# on its own.
pause_writes || true
if [ -n "$target" ] && [ "$new_master" != "$target" ]; then
  log "Sentinel promoted $new_master, not $target"
fi
log "handed the master role over to $new_master at offset $target_offset"
