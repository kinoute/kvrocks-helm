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
}

test_the_former_master_is_demoted_at_once() {
  former_master
  reconfig
  assert_eq 0 "$STATUS" "exit status"
  assert_called "localhost:6379 slaveof kv-1.h 6379"
  assert_called "localhost:6379 client kill type normal"
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
