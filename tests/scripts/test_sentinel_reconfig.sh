# image: sentinel
# The script Sentinel runs on a master change, in the pod of the former master kv-0.

reconfig() { # Sets STATUS; 124 if it hangs.
  STATUS=0
  DEMOTE_TIMEOUT_SECONDS=3 timeout 30 \
    /scripts/sentinel-reconfig.sh kvrocks leader start kv-0.h 6379 kv-1.h 6379 >"$WORLD/out" 2>&1 || STATUS=$?
}

former_master() {
  kvrocks_master localhost
  reply localhost:6379 "client kill" "2"
  reply localhost:6379 "config rewrite" "OK"
  step_down_on_slaveof
  # The Sentinel of the pod, which runs the script, names the new master before it starts it.
  sentinel_names localhost kv-1.h 2
}

test_the_former_master_is_demoted_at_once() {
  former_master
  reconfig
  assert_eq 0 "$STATUS" "exit status"
  assert_called "localhost:6379 slaveof kv-1.h 6379"
  assert_called "localhost:6379 client kill type normal"
}

test_a_new_master_that_reports_itself_master_is_followed() {
  former_master
  kvrocks_master kv-1.h
  reconfig
  assert_eq 0 "$STATUS" "exit status"
  assert_called "localhost:6379 slaveof kv-1.h 6379"
}

# A hello of an old Sentinel, replayed from a restored write-ahead log, named kv-1, which
# follows kv-0: following it back would leave the cluster with no master.
test_a_new_master_that_reports_itself_a_replica_is_not_followed() {
  former_master
  kvrocks_replica kv-1.h kv-0.h
  reconfig
  assert_eq 1 "$STATUS" "exit status: Sentinel must run it again"
  assert_not_called "slaveof"
  grep -q "kv-1.h reports itself a replica" "$WORLD/out" || fail "expected the reason in the log"
}

test_a_run_replayed_after_a_later_failover_leaves_the_new_master_alone() {
  former_master
  # Since the failover this run was started for, another one made kv-0 the master again.
  sentinel_names localhost kv-0.h 3
  reconfig
  assert_eq 0 "$STATUS" "exit status"
  assert_not_called "slaveof"
}

test_a_sentinel_that_does_not_answer_does_not_hold_the_demotion_back() {
  former_master
  down localhost:26379
  reconfig
  assert_eq 0 "$STATUS" "exit status"
  assert_called "localhost:6379 slaveof kv-1.h 6379"
}

test_nothing_to_do_in_the_pod_of_another_master() {
  former_master
  STATUS=0
  /scripts/sentinel-reconfig.sh kvrocks leader start kv-2.h 6379 kv-1.h 6379 >/dev/null 2>&1 || STATUS=$?
  assert_eq 0 "$STATUS" "exit status"
  assert_not_called "slaveof"
}

test_a_kvrocks_already_replica_needs_nothing() {
  kvrocks_replica localhost kv-1.h
  reconfig
  assert_eq 0 "$STATUS" "exit status"
  assert_not_called "slaveof"
}

test_a_kvrocks_that_does_not_answer_makes_sentinel_retry() {
  down localhost:6379
  reconfig
  assert_eq 1 "$STATUS" "exit status"
}

test_a_demotion_that_does_not_take_makes_sentinel_retry() {
  former_master
  reply localhost:6379 "slaveof" "ERR Can not resolve hostname"
  reconfig
  assert_eq 1 "$STATUS" "exit status"
  [ "$(calls | grep -c 'slaveof kv-1.h')" -gt 1 ] || fail "the demotion should be retried"
}
