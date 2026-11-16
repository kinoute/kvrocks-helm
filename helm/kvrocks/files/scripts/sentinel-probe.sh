#!/bin/sh
# Liveness and readiness probe of the sentinel container.
SCRIPT_NAME=sentinel-probe
# shellcheck source=common.sh
. /scripts/common.sh

[ "$(sentinel_cli localhost ping)" = "PONG" ]
