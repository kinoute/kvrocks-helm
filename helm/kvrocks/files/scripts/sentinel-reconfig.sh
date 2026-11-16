#!/bin/sh
# Sentinel runs this on every master change (client-reconfig-script):
#   <master-name> <role> <state> <from-host> <from-port> <to-host> <to-port>
#
# Sentinel itself only demotes the old master about ten seconds after the switch. Until then
# it still accepts writes, and they are discarded once it becomes a replica. The Sentinel
# that shares a pod with the old master demotes it right away instead.
SCRIPT_NAME=sentinel-reconfig
# shellcheck source=common.sh
. /scripts/common.sh

from_host=$4
to_host=$6
to_port=$7

[ "$from_host" = "$(self_fqdn)" ] || exit 0
[ "$(kv_info_field localhost role)" = "master" ] || exit 0

log "demoting the local Kvrocks, new master is $to_host"
kv_cli localhost slaveof "$to_host" "$to_port" >/dev/null
# Connected clients must reconnect and reach the new master.
kv_cli localhost client kill type normal >/dev/null
kv_cli localhost config rewrite >/dev/null
exit 0
