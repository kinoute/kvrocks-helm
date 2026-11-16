#!/bin/sh
# Runs the test_* functions of one test file, each in a world of its own.
# Usage (inside the image the scripts under test run in): harness.sh <test file>
# shellcheck disable=SC2329,SC2034  # the helpers are called by the sourced test files
PATH=/tests/fake:$PATH
export PATH

# The topology the scripts see: three pods kv-0, kv-1 and kv-2 in domain h, and this is kv-0.
export POD_NAME=kv-0 KVROCKS_STATEFULSET=kv KVROCKS_PEERS_DOMAIN=h KVROCKS_REPLICAS=3
export KVROCKS_PORT=6379 SENTINEL_PORT=26379 SENTINEL_MASTER_NAME=kvrocks SENTINEL_MAJORITY=2
export KVROCKS_ARCHITECTURE=replication SWITCHOVER_PAUSE_MS=5000 SENTINEL_FAILOVER_TIMEOUT_MS=3000

# --- World ---

server() { # $1: host:port. Makes it reachable.
  mkdir -p "$WORLD/$1"
  rm -f "$WORLD/$1/down" "$WORLD/$1/hang"
}

down() { # $1: host:port
  mkdir -p "$WORLD/$1"
  touch "$WORLD/$1/down"
}

hang() { # $1: host:port
  mkdir -p "$WORLD/$1"
  touch "$WORLD/$1/hang"
}

reply() { # $1: host:port, $2: command, $3: reply. Replaces a handler of the same command.
  server "$1"
  file="$WORLD/$1/$(printf '%s' "$2" | tr '[:upper:] ' '[:lower:]_')"
  rm -f "$file"
  printf '%s\n' "$3" >"$file"
}

handler() { # $1: host:port, $2: command; the script comes on stdin and runs on each call
  server "$1"
  file="$WORLD/$1/$(printf '%s' "$2" | tr '[:upper:] ' '[:lower:]_')"
  cat >"$file"
  chmod +x "$file"
}

kvrocks_master() { # $1: host
  reply "$1:6379" "info replication" "# Replication
role:master
connected_slaves:2
master_repl_offset:${2:-100}"
}

kvrocks_replica() { # $1: host, $2: master, $3: offset, $4: link status
  reply "$1:6379" "info replication" "# Replication
role:slave
master_host:$2
master_port:6379
master_link_status:${4:-up}
master_sync_in_progress:0
slave_repl_offset:${3:-100}"
}

sentinel_names() { # $1: Sentinel host, $2: master pod, $3: config epoch
  reply "$1:26379" "sentinel get-master-addr-by-name kvrocks" "$2
6379"
  reply "$1:26379" "sentinel master kvrocks" "name
kvrocks
ip
$2
flags
master
config-epoch
$3"
}

sentinel_replicas() { # $1: Sentinel host, then "<host> <flags> <last-ok-ping-reply ms> <priority>" per replica
  sentinel=$1
  shift
  out=""
  for replica in "$@"; do
    # shellcheck disable=SC2086  # one word per field
    set -- $replica
    out="${out}name
$1:6379
ip
$1
flags
$2
last-ok-ping-reply
$3
slave-priority
$4
"
  done
  reply "$sentinel:26379" "sentinel replicas kvrocks" "$out"
}

# Makes SENTINEL FAILOVER on $1 succeed: every Sentinel then names $2, at epoch $3.
promote_on_failover() { # $1: Sentinel host, $2: new master, $3: new epoch
  handler "$1:26379" "sentinel failover kvrocks" <<HANDLER
for sentinel in localhost kv-1.h kv-2.h; do
  dir="\$WORLD/\$sentinel:26379"
  [ -d "\$dir" ] || continue
  printf '%s\n%s\n' "$2" 6379 >"\$dir/sentinel_get-master-addr-by-name_kvrocks"
  printf 'name\nkvrocks\nip\n%s\nflags\nmaster\nconfig-epoch\n%s\n' "$2" "$3" >"\$dir/sentinel_master_kvrocks"
done
echo OK
HANDLER
}

# Makes SLAVEOF on the local Kvrocks turn it into a replica.
step_down_on_slaveof() {
  handler localhost:6379 "slaveof" <<'HANDLER'
printf '# Replication\nrole:slave\nmaster_host:%s\nmaster_link_status:up\nmaster_sync_in_progress:0\nslave_repl_offset:100\n' "$2" \
  >"$WORLD/localhost:6379/info_replication"
echo OK
HANDLER
}

dns() { # $1: name, $2: address
  mkdir -p "$WORLD/dns"
  printf '%s\n' "$2" >"$WORLD/dns/$1"
}

calls() {
  cat "$WORLD/calls" 2>/dev/null
}

# --- Assertions ---

fail() {
  echo "    $*"
  exit 1
}

assert_eq() { # $1: expected, $2: actual, $3: what
  [ "$1" = "$2" ] || fail "$3: expected [$1], got [$2]"
}

assert_called() { # $1: start of a call, e.g. "localhost:6379 client pause"
  calls | grep -q -F -- "$1" || fail "expected a call to [$1]; calls were:
$(calls | sed 's/^/      /')"
}

assert_not_called() { # $1: start of a call
  if calls | grep -q -F -- "$1"; then
    fail "unexpected call to [$1]"
  fi
}

# --- Runner ---

# shellcheck disable=SC1090  # the test file is the argument
. "$1"
failed=0
for test in $(grep -o '^test_[a-z0-9_]*()' "$1" | tr -d '()'); do
  WORLD=$(mktemp -d)
  export WORLD
  if output=$( (set -e; "$test") 2>&1); then
    echo "  ok      $test"
  else
    echo "  FAILED  $test"
    printf '%s\n' "$output" | sed 's/^/    /'
    failed=1
  fi
done
exit "$failed"
