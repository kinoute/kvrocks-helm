#!/bin/sh
# Readiness probe of the sentinel container.
SCRIPT_NAME=sentinel-probe
# shellcheck source=common.sh
. /scripts/common.sh

reply=$(sentinel_cli localhost ping)
[ "$reply" = "PONG" ] && exit 0
# Kubernetes shows what a failed probe printed in the events of the pod. A Sentinel stalled
# on a name lookup, during a DNS outage for instance, gives no reply at all.
printf 'not ready: Sentinel answers PING with [%s]\n' "${reply:-no reply within $CLI_TIMEOUT_SECONDS s}"
exit 1
