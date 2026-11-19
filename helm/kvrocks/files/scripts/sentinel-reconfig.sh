#!/bin/sh
# Sentinel runs this on every master change (client-reconfig-script):
#   <master-name> <role> <state> <from-host> <from-port> <to-host> <to-port>
#
# Sentinel itself only demotes the old master about ten seconds after the switch. Until then
# it still accepts writes, and they are discarded once it becomes a replica. The Sentinel
# that shares a pod with the old master demotes it right away instead.
#
# Exit status 1 makes Sentinel run the script again later (up to 10 times), so it is used
# whenever the demotion could not be confirmed. 0 means there is nothing left to do.
SCRIPT_NAME=sentinel-reconfig
# shellcheck source=common.sh
. /scripts/common.sh

# Sentinel kills a script that runs longer than 60 s. Shorter in the unit tests.
DEMOTE_TIMEOUT_SECONDS=${DEMOTE_TIMEOUT_SECONDS:-45}
RETRY_SECONDS=1
SENTINEL_TIMEOUT_SECONDS=1
NEW_MASTER_TIMEOUT_SECONDS=1

from_host=$4
to_host=$6
to_port=$7

[ "$from_host" = "$(self_fqdn)" ] || exit 0

# Sentinel replays a failed run with the arguments it was first given, up to minutes later.
# By then another failover may have made this pod the master again, and demoting it would
# leave the cluster without one. The Sentinel of this pod runs the script, and names the new
# master before it starts it: if it names another pod by now, this run is out of date.
# A Sentinel that does not answer proves nothing, and does not hold the demotion back.
out_of_date() {
  local master
  master=$(
    CLI_TIMEOUT_SECONDS=$SENTINEL_TIMEOUT_SECONDS
    sentinel_master localhost
  )
  [ -n "$master" ] && [ "$master" != "$to_host" ]
}

# Sentinel names a master only once it reports itself one. A new master that reports itself a
# replica comes from a stale message, such as a hello of an old Sentinel replayed from a restored
# write-ahead log: following it, this pod would follow its own replica, and the cluster would be
# left with no master. A new master that does not answer is followed all the same: stopping the
# writes here is what keeps them from being lost.
new_master_is_a_replica() {
  local role
  role=$(
    CLI_TIMEOUT_SECONDS=$NEW_MASTER_TIMEOUT_SECONDS
    kv_role "$to_host"
  )
  [ "$role" = "slave" ]
}

deadline=$(($(date +%s) + DEMOTE_TIMEOUT_SECONDS))
attempt=1
while true; do
  case "$(kv_role localhost)" in
    slave)
      [ "$attempt" -eq 1 ] || log "the local Kvrocks now follows $to_host"
      exit 0
      ;;
    master)
      if out_of_date; then
        log "Sentinel no longer names $to_host as master: the local Kvrocks is left as it is"
        exit 0
      fi
      if new_master_is_a_replica; then
        [ "$attempt" -gt 1 ] || log "$to_host reports itself a replica: the local Kvrocks stays master for now"
      else
        [ "$attempt" -gt 1 ] || log "demoting the local Kvrocks, new master is $to_host"
        kv_cli localhost slaveof "$to_host" "$to_port" >/dev/null || true
        # Connected clients must reconnect and reach the new master.
        kv_cli localhost client kill type normal >/dev/null || true
        kv_cli localhost config rewrite >/dev/null || true
      fi
      ;;
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "could not confirm the demotion of the local Kvrocks, Sentinel will run this again"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep "$RETRY_SECONDS"
done
