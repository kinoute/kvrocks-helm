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

# The probe must answer well within its timeoutSeconds (5 s by default).
PROBE_CLI_TIMEOUT_SECONDS=1

# Kubernetes shows what a failed probe printed in the events of the pod: say why.
not_ready() { # $1: why
  printf 'not ready: %s\n' "$1"
}
# A Sentinel that does not answer within this time counts as one that cannot promote us.
SENTINEL_PROBE_TIMEOUT_SECONDS=0.5

# One line per Sentinel that answers: "yes" if it could promote this replica, "no" if not.
sentinel_opinions() {
  local host
  for host in localhost $(peer_fqdns); do
    (
      CLI_TIMEOUT_SECONDS=$SENTINEL_PROBE_TIMEOUT_SECONDS
      # Read the reply, never the exit status: an error reply, as NOAUTH, says no, whether this
      # redis-cli exits 0 on it or not. No reply at all is a Sentinel that does not answer.
      reply=$(sentinel_cli "$host" sentinel replicas "$SENTINEL_MASTER_NAME")
      [ -n "$reply" ] || exit 0
      if printf '%s\n' "$reply" | promotable_replicas_from_reply | grep -q -x -F "$(self_fqdn)"; then
        echo yes
      else
        echo no
      fi
    ) &
  done | sort
}

# A majority of Sentinels must be able to promote this replica. If fewer than a majority
# answer at all, as during a cluster DNS outage, when Sentinel stalls on name lookups, every
# one that answers must be able to; if none answers, the replication link alone decides.
promotable_enough() {
  local opinions answered promotable
  opinions=$(sentinel_opinions)
  answered=$(printf '%s\n' "$opinions" | grep -c -E '^(yes|no)$' || true)
  promotable=$(printf '%s\n' "$opinions" | grep -c -x yes || true)
  [ "$promotable" -ge "$SENTINEL_MAJORITY" ] && return 0
  [ "$answered" -lt "$SENTINEL_MAJORITY" ] && [ "$promotable" -eq "$answered" ] && return 0
  not_ready "$promotable of the $answered Sentinels that answered could promote it, $SENTINEL_MAJORITY needed"
  return 1
}

field() { # $1: INFO replication output, $2: field
  printf '%s\n' "$1" | awk -F: -v field="$2" '$1 == field { print $2 }'
}

# How many times a replica reads its own offset before it is called behind.
OFFSET_READS=3

# The link and the sync flag do not tell whether a replica has caught up. A replica that is
# far behind, or came back empty, is let in wherever the write-ahead log of the master still
# reaches, its first write included: Kvrocks then reports the link up and no sync in
# progress while the replica replays that log, millions of writes at times.
#
# So the replica must hold every write its master held a moment ago. The offset of the
# master is read first: under load, a replica that follows closely is a few writes short
# of it at most, and gets there within another read. A master that does not answer leaves
# the decision to the link.
caught_up() { # $1: master host
  local target offset reads=0
  target=$(
    CLI_TIMEOUT_SECONDS=$PROBE_CLI_TIMEOUT_SECONDS
    kv_info_field "$1" master_repl_offset
  )
  case "$target" in
    "" | *[!0-9]*) return 0 ;;
  esac
  while [ "$reads" -lt "$OFFSET_READS" ]; do
    offset=$(
      CLI_TIMEOUT_SECONDS=$PROBE_CLI_TIMEOUT_SECONDS
      kv_info_field localhost slave_repl_offset
    )
    case "$offset" in
      "" | *[!0-9]*)
        not_ready "it does not give its own offset"
        return 1
        ;;
    esac
    [ "$offset" -lt "$target" ] || return 0
    reads=$((reads + 1))
  done
  not_ready "it holds offset $offset, its master $1 held $target a moment ago"
  return 1
}

# A replica is ready once it follows its master, has finished syncing, has caught up with
# it, and Sentinel could promote it. The rolling update waits for readiness, so it never
# stops the next pod, the master maybe, while this one is still catching up or out of
# Sentinel's reach.
is_ready() {
  local info master reason
  info=$(
    CLI_TIMEOUT_SECONDS=$PROBE_CLI_TIMEOUT_SECONDS
    kv_cli localhost info replication | tr -d '\r'
  )
  case "$(field "$info" role)" in
    master) return 0 ;;
    slave) ;;
    *)
      # An error reply, NOAUTH after a password change for instance, says more than no role.
      reason=$(printf '%s\n' "$info" | grep -v -e '^#' -e '^$' | head -n 1)
      not_ready "Kvrocks gives no role${reason:+: $reason}"
      return 1
      ;;
  esac
  master=$(field "$info" master_host)
  if [ "$(field "$info" master_link_status)" != "up" ]; then
    not_ready "its link to the master $master is down"
    return 1
  fi
  if [ "$(field "$info" master_sync_in_progress)" != "0" ]; then
    not_ready "it is copying the whole database from the master $master"
    return 1
  fi
  caught_up "$master" || return 1
  [ "$KVROCKS_ARCHITECTURE" != "replication" ] || promotable_enough
}

case "${1:-}" in
  startup | liveness) answers ;;
  readiness) is_ready ;;
  *)
    log "unknown probe: ${1:-}"
    exit 2
    ;;
esac
