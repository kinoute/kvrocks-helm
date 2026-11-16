#!/bin/sh
# preStop hook of the kvrocks container.
# A master hands its role over before it stops, so a rolling update loses no write.
# If the handover fails the pod still stops, and Sentinel fails over as it would after a crash.
#
# Sentinel runs as a sidecar: Kubernetes only stops it once this container has exited, so
# it is still there for the handover.
SCRIPT_NAME=kvrocks-prestop
# shellcheck source=common.sh
. /scripts/common.sh

# The output of a hook is not in the container logs. The last handovers are kept on the data
# volume, where they survive the restart: kubectl exec <pod> -- cat /var/lib/kvrocks/handover.log
HANDOVER_LOG="$DATA_DIR/handover.log"
HANDOVER_LOG_LINES=200

[ "$KVROCKS_ARCHITECTURE" = "replication" ] || exit 0

output=$(/scripts/kvrocks-switchover.sh --stopping 2>&1)
status=$?
{
  [ -f "$HANDOVER_LOG" ] && tail -n "$HANDOVER_LOG_LINES" "$HANDOVER_LOG"
  printf '%s\n' "$output"
  log "handover exited with status $status" 2>&1
} >"$HANDOVER_LOG.tmp" && mv "$HANDOVER_LOG.tmp" "$HANDOVER_LOG"

# A failed hook shows up as a FailedPreStopHook event on the pod, with this output.
if [ "$status" -ne 0 ]; then
  printf '%s\n' "$output" >&2
  log "handover failed, falling back to a regular failover"
  exit 1
fi
