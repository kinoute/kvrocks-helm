# image: kvrocks
# The handover: every way it can end, and what it leaves behind.

# kv-0 is master at offset 100, kv-1 and kv-2 hold every write, all Sentinels name kv-0, and a
# failover promotes kv-1.
cluster_ready() {
  kvrocks_master localhost 100
  kvrocks_replica kv-1.h kv-0.h 100
  kvrocks_replica kv-2.h kv-0.h 100
  for sentinel in localhost kv-1.h kv-2.h; do
    sentinel_names "$sentinel" kv-0.h 1
  done
  sentinel_replicas localhost "kv-1.h slave 300 100" "kv-2.h slave 300 100"
  reply localhost:6379 "client pause" "OK"
  reply localhost:6379 "client unpause" "OK"
  reply localhost:6379 "client kill" "2"
  reply localhost:6379 "config rewrite" "OK"
  promote_on_failover localhost kv-1.h 2
  step_down_on_slaveof
}

switchover() { # $@: arguments of the script. Sets STATUS; 124 if it hangs.
  STATUS=0
  timeout 30 /scripts/kvrocks-switchover.sh "$@" >"$WORLD/out" 2>&1 || STATUS=$?
}

test_a_handover_promotes_a_replica_and_steps_down() {
  cluster_ready
  switchover
  assert_eq 0 "$STATUS" "exit status"
  assert_called "localhost:26379 sentinel failover kvrocks"
  assert_called "localhost:6379 slaveof kv-1.h 6379"
  assert_called "localhost:6379 client kill type normal"
  assert_called "localhost:6379 client unpause"
  first_pause=$(calls | grep -n 'client pause' | head -n 1 | cut -d: -f1)
  failover=$(calls | grep -n 'sentinel failover' | cut -d: -f1)
  [ "$first_pause" -lt "$failover" ] || fail "writes must be paused before the failover"
}

test_a_replica_has_nothing_to_hand_over() {
  cluster_ready
  kvrocks_replica localhost kv-1.h
  switchover
  assert_eq 0 "$STATUS" "exit status"
  assert_not_called "localhost:6379 client pause"
}

test_a_kvrocks_that_does_not_answer_is_not_taken_for_a_replica() {
  cluster_ready
  down localhost:6379
  switchover --stopping
  assert_eq 1 "$STATUS" "exit status"
  assert_not_called "sentinel failover"
}

test_no_handover_when_no_sentinel_names_this_pod() {
  cluster_ready
  for sentinel in localhost kv-1.h kv-2.h; do
    sentinel_names "$sentinel" kv-1.h 2
  done
  switchover
  assert_eq 1 "$STATUS" "exit status"
  assert_not_called "localhost:6379 client pause"
}

test_no_handover_on_a_kvrocks_that_cannot_pause_writes() {
  cluster_ready
  reply localhost:6379 "client pause" "ERR syntax error"
  switchover
  assert_eq 1 "$STATUS" "exit status"
  assert_not_called "sentinel failover"
}

test_a_replica_behind_cancels_the_handover_and_writes_resume() {
  cluster_ready
  kvrocks_replica kv-2.h kv-0.h 50
  switchover
  assert_eq 1 "$STATUS" "exit status"
  assert_not_called "sentinel failover"
  assert_called "localhost:6379 client unpause"
}

test_when_stopping_a_cancelled_handover_keeps_writes_paused() {
  cluster_ready
  kvrocks_replica kv-2.h kv-0.h 50
  switchover --stopping
  assert_eq 1 "$STATUS" "exit status"
  assert_not_called "sentinel failover"
  assert_not_called "localhost:6379 client unpause"
}

test_a_replica_sentinel_cannot_promote_may_be_behind() {
  cluster_ready
  kvrocks_replica kv-2.h kv-0.h 50
  sentinel_replicas localhost "kv-1.h slave 300 100" "kv-2.h slave,s_down 300 100"
  switchover
  assert_eq 0 "$STATUS" "exit status"
  assert_called "localhost:6379 slaveof kv-1.h 6379"
}

test_a_replica_with_priority_0_may_be_behind() {
  cluster_ready
  kvrocks_replica kv-2.h kv-0.h 50
  sentinel_replicas localhost "kv-1.h slave 300 100" "kv-2.h slave 300 0"
  switchover
  assert_eq 0 "$STATUS" "exit status"
}

test_a_refused_failover_cancels_the_handover() {
  cluster_ready
  reply localhost:26379 "sentinel failover kvrocks" "NOGOODSLAVE No suitable replica to promote"
  switchover
  assert_eq 1 "$STATUS" "exit status"
  assert_called "localhost:6379 client unpause"
}

test_an_unanswered_failover_that_did_start_is_seen_through() {
  cluster_ready
  hang_failover_request
  reply localhost:26379 "sentinel master kvrocks" "name
kvrocks
ip
kv-0.h
flags
master,failover_in_progress
config-epoch
1"
  sentinel_names kv-1.h kv-1.h 2
  switchover
  assert_eq 0 "$STATUS" "exit status"
  assert_called "localhost:6379 slaveof kv-1.h 6379"
}

test_an_unanswered_failover_that_did_not_start_is_given_up() {
  cluster_ready
  hang_failover_request
  switchover
  assert_eq 1 "$STATUS" "exit status"
  assert_called "localhost:6379 client unpause"
  assert_not_called "localhost:6379 slaveof"
}

test_a_master_that_will_not_step_down_keeps_its_writes_paused() {
  cluster_ready
  reply localhost:6379 "slaveof" "OK"
  switchover
  assert_eq 1 "$STATUS" "exit status"
  assert_called "localhost:6379 slaveof kv-1.h 6379"
  assert_not_called "localhost:6379 client unpause"
}

# The failover request gets no answer within the script's timeout.
hang_failover_request() {
  handler localhost:26379 "sentinel failover kvrocks" <<'HANDLER'
sleep 3600
HANDLER
}
