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
  assert_called "localhost:6379 client pause 3000 write"
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
