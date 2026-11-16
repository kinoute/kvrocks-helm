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
# A Sentinel that does not answer within this time counts as one that cannot promote us.
SENTINEL_PROBE_TIMEOUT_SECONDS=0.5

# One line per Sentinel that answers: "yes" if it could promote this replica, "no" if not.
sentinel_opinions() {
  local host
  for host in localhost $(peer_fqdns); do
    (
      CLI_TIMEOUT_SECONDS=$SENTINEL_PROBE_TIMEOUT_SECONDS
      reply=$(sentinel_cli "$host" sentinel replicas "$SENTINEL_MASTER_NAME") || exit 0
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
  [ "$answered" -lt "$SENTINEL_MAJORITY" ] && [ "$promotable" -eq "$answered" ]
}

field() { # $1: INFO replication output, $2: field
  printf '%s\n' "$1" | awk -F: -v field="$2" '$1 == field { print $2 }'
}

# A replica is ready once it follows its master, has finished syncing, and Sentinel could
# promote it. The rolling update waits for readiness, so it never stops the next pod, the
# master maybe, while this one is still catching up or out of Sentinel's reach.
is_ready() {
  local info
  info=$(
    CLI_TIMEOUT_SECONDS=$PROBE_CLI_TIMEOUT_SECONDS
    kv_cli localhost info replication | tr -d '\r'
  )
  case "$(field "$info" role)" in
    master) return 0 ;;
    slave)
      [ "$(field "$info" master_link_status)" = "up" ] &&
        [ "$(field "$info" master_sync_in_progress)" = "0" ] &&
        { [ "$KVROCKS_ARCHITECTURE" != "replication" ] || promotable_enough; }
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
