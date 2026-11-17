# image: kvrocks
# The fencing sidecar, run for a few seconds against a world that changes under it.

# kv-0 is master, the three Sentinels confirm it, peers resolve to 10.0.0.1 and 10.0.0.2.
healthy_master() {
  kvrocks_master localhost
  reply localhost:6379 "client pause" "OK"
  reply localhost:6379 "client unpause" "OK"
  dns kv-1.h 10.0.0.1
  dns kv-2.h 10.0.0.2
  sentinel_names localhost kv-0.h 1
  sentinel_names 10.0.0.1 kv-0.h 1
  sentinel_names 10.0.0.2 kv-0.h 1
}

start_fence() {
  /scripts/kvrocks-fence.sh >"$WORLD/fence.log" 2>&1 &
  FENCE_PID=$!
}

stop_fence() {
  kill "$FENCE_PID" 2>/dev/null || true
  wait "$FENCE_PID" 2>/dev/null || true
}

# The node of the master is cut off, cluster DNS included: no lookup and no peer answers,
# and each of them costs the fencing loop a full timeout.
isolate_from() { # the addresses of the peers
  touch "$WORLD/dns-down"
  for address in "$@"; do
    hang "$address:26379"
    hang "$address:6379"
  done
}

# Records every pause Kvrocks is asked for, as "<when, in ms> <for how long, in ms>".
record_pauses() {
  handler localhost:6379 "client pause" <<'HANDLER'
echo "$(date +%s%3N) $3" >>"$WORLD/pauses"
echo OK
HANDLER
}

pauses() {
  cat "$WORLD/pauses" 2>/dev/null
}

# Writes go through whenever a pause runs out before the next one starts.
assert_no_gap_between_pauses() {
  [ "$(pauses | wc -l)" -ge 2 ] || fail "the pause was not renewed; pauses were:
$(pauses | sed 's/^/      /')"
  pauses | awk 'NR > 1 && $1 - started >= lasts { exit 1 } { started = $1; lasts = $2 }' ||
    fail "a pause ran out before the next one started; pauses were (when, how long, in ms):
$(pauses | sed 's/^/      /')"
}

test_a_confirmed_master_is_never_paused() {
  healthy_master
  start_fence
  sleep 4
  stop_fence
  assert_not_called "localhost:6379 client pause"
}

test_a_master_cut_off_from_its_peers_is_paused() {
  healthy_master
  start_fence
  sleep 2
  down 10.0.0.1:26379
  down 10.0.0.2:26379
  sleep 4
  stop_fence
  assert_called "localhost:6379 client pause 10000 write"
}

test_a_pause_is_renewed_before_it_runs_out() {
  healthy_master
  record_pauses
  start_fence
  sleep 2
  isolate_from 10.0.0.1 10.0.0.2
  sleep 10
  stop_fence
  assert_no_gap_between_pauses
}

# Every peer adds lookups and probes that time out: the checks must not slow down with them.
test_a_pause_is_renewed_before_it_runs_out_with_five_pods() {
  export KVROCKS_REPLICAS=5 SENTINEL_MAJORITY=3
  healthy_master
  dns kv-3.h 10.0.0.3
  dns kv-4.h 10.0.0.4
  sentinel_names 10.0.0.3 kv-0.h 1
  sentinel_names 10.0.0.4 kv-0.h 1
  record_pauses
  start_fence
  sleep 2
  isolate_from 10.0.0.1 10.0.0.2 10.0.0.3 10.0.0.4
  sleep 10
  stop_fence
  assert_no_gap_between_pauses
}

test_a_refused_pause_is_reported_and_tried_again() {
  healthy_master
  reply localhost:6379 "client pause" "ERR unknown subcommand 'pause'"
  start_fence
  sleep 2
  down 10.0.0.1:26379
  down 10.0.0.2:26379
  sleep 4
  stop_fence
  grep -q 'refused to pause writes' "$WORLD/fence.log" || fail "no warning; log was:
$(cat "$WORLD/fence.log")"
  if grep -q 'writes paused' "$WORLD/fence.log"; then
    fail "the log claims writes are paused"
  fi
  [ "$(calls | grep -c -F 'localhost:6379 client pause')" -ge 2 ] || fail "the pause was not tried again"
}

test_a_master_never_confirmed_is_not_paused() {
  healthy_master
  down 10.0.0.1:26379
  down 10.0.0.2:26379
  start_fence
  sleep 4
  stop_fence
  assert_not_called "localhost:6379 client pause"
}

test_a_fenced_master_that_stops_answering_stays_fenced() {
  healthy_master
  start_fence
  sleep 2
  down 10.0.0.1:26379
  down 10.0.0.2:26379
  sleep 4
  assert_called "localhost:6379 client pause"
  down localhost:6379
  sleep 2
  server localhost:6379
  : >"$WORLD/calls"
  sleep 2
  stop_fence
  assert_not_called "localhost:6379 client unpause"
  assert_called "localhost:6379 client pause"
}

test_a_fenced_master_demoted_to_replica_is_released() {
  healthy_master
  start_fence
  sleep 2
  down 10.0.0.1:26379
  down 10.0.0.2:26379
  sleep 4
  kvrocks_replica localhost kv-1.h
  sleep 2
  stop_fence
  assert_called "localhost:6379 client unpause"
}

test_a_master_followed_again_leaves_a_pause_of_the_handover_alone() {
  healthy_master
  start_fence
  sleep 2
  down 10.0.0.1:26379
  down 10.0.0.2:26379
  sleep 4
  assert_called "localhost:6379 client pause"
  held_by handover 60000
  server 10.0.0.1:26379
  server 10.0.0.2:26379
  sleep 3
  stop_fence
  assert_not_called "localhost:6379 client unpause"
  grep -q 'the handover still holds them' "$WORLD/fence.log" || fail "no word of the handover; log was:
$(cat "$WORLD/fence.log")"
}

test_a_master_its_replicas_still_follow_is_not_paused() {
  healthy_master
  kvrocks_replica 10.0.0.1 kv-0.h
  start_fence
  sleep 2
  # The Sentinels stall, as on name lookups during a DNS outage; replication goes on.
  hang localhost:26379
  hang 10.0.0.1:26379
  hang 10.0.0.2:26379
  sleep 4
  stop_fence
  assert_not_called "localhost:6379 client pause"
}

test_a_replica_that_follows_another_master_does_not_count() {
  healthy_master
  kvrocks_replica 10.0.0.1 kv-2.h
  start_fence
  sleep 2
  down localhost:26379
  down 10.0.0.1:26379
  down 10.0.0.2:26379
  sleep 4
  stop_fence
  assert_called "localhost:6379 client pause"
}

test_a_dns_outage_does_not_pause_a_healthy_master() {
  healthy_master
  start_fence
  sleep 2
  touch "$WORLD/dns-down"
  sleep 5
  stop_fence
  assert_not_called "localhost:6379 client pause"
}
