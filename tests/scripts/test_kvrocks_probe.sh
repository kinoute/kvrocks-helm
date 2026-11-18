# image: kvrocks
# The readiness probe of the kvrocks container, on kv-0.

ready() { # Sets STATUS.
  STATUS=0
  timeout 10 /scripts/kvrocks-probe.sh readiness >/dev/null 2>&1 || STATUS=$?
}

# kv-0 replicates kv-1, and all three Sentinels could promote it.
promotable_replica() {
  kvrocks_replica localhost kv-1.h
  for sentinel in localhost kv-1.h kv-2.h; do
    sentinel_replicas "$sentinel" "kv-0.h slave 300 100" "kv-2.h slave 300 100"
  done
}

test_a_master_is_ready() {
  kvrocks_master localhost
  ready
  assert_eq 0 "$STATUS" "exit status"
}

test_a_replica_every_sentinel_could_promote_is_ready() {
  promotable_replica
  ready
  assert_eq 0 "$STATUS" "exit status"
}

test_a_replica_only_one_sentinel_could_promote_is_not_ready() {
  promotable_replica
  sentinel_replicas kv-1.h "kv-0.h slave,disconnected 300 100"
  sentinel_replicas kv-2.h "kv-0.h slave 9000 100"
  ready
  assert_eq 1 "$STATUS" "exit status"
}

test_a_replica_a_majority_could_promote_is_ready() {
  promotable_replica
  sentinel_replicas kv-2.h "kv-0.h slave,s_down 300 100"
  ready
  assert_eq 0 "$STATUS" "exit status"
}

# Some redis-cli exit 1 on an error reply: it is still an answer, and it says no.
test_sentinels_that_answer_an_error_do_not_make_a_replica_ready() {
  promotable_replica
  for sentinel in localhost kv-1.h kv-2.h; do
    handler "$sentinel:26379" "sentinel replicas kvrocks" <<'HANDLER'
echo "NOAUTH Authentication required."
exit 1
HANDLER
  done
  ready
  assert_eq 1 "$STATUS" "exit status"
}

test_during_a_dns_outage_the_sentinels_that_answer_decide() {
  promotable_replica
  dns kv-1.h 10.0.0.1
  dns kv-2.h 10.0.0.2
  touch "$WORLD/dns-down"
  ready
  assert_eq 0 "$STATUS" "exit status"
}

test_a_replica_still_syncing_is_not_ready() {
  promotable_replica
  reply localhost:6379 "info replication" "role:slave
master_host:kv-1.h
master_link_status:up
master_sync_in_progress:1"
  ready
  assert_eq 1 "$STATUS" "exit status"
}

# The master let it in at an old point of its log: the link is up, the writes are not there yet.
test_a_replica_still_replaying_the_log_of_its_master_is_not_ready() {
  promotable_replica
  kvrocks_replica localhost kv-1.h 40
  kvrocks_master kv-1.h 100
  ready
  assert_eq 1 "$STATUS" "exit status"
}

test_a_replica_that_reached_the_offset_of_its_master_is_ready() {
  promotable_replica
  kvrocks_replica localhost kv-1.h 100
  kvrocks_master kv-1.h 100
  ready
  assert_eq 0 "$STATUS" "exit status"
  assert_called "kv-1.h:6379 info replication"
}

# Under load, the replica has moved on since the offset of the master was read.
test_a_replica_past_the_offset_read_on_its_master_is_ready() {
  promotable_replica
  kvrocks_replica localhost kv-1.h 120
  kvrocks_master kv-1.h 100
  ready
  assert_eq 0 "$STATUS" "exit status"
}

# Under load again: a few writes short of the master at first, there on the next read.
test_a_replica_that_reaches_its_master_on_another_read_is_ready() {
  promotable_replica
  kvrocks_master kv-1.h 100
  handler localhost:6379 "info replication" <<'HANDLER'
reads=$(cat "$WORLD/reads" 2>/dev/null || echo 0)
echo $((reads + 1)) >"$WORLD/reads"
offset=95
[ "$reads" -lt 2 ] || offset=100
printf 'role:slave\nmaster_host:kv-1.h\nmaster_link_status:up\nmaster_sync_in_progress:0\nslave_repl_offset:%s\n' "$offset"
HANDLER
  ready
  assert_eq 0 "$STATUS" "exit status"
}

test_a_replica_whose_master_does_not_answer_is_ready_on_its_link() {
  promotable_replica
  kvrocks_replica localhost kv-1.h 40
  hang kv-1.h:6379
  ready
  assert_eq 0 "$STATUS" "exit status"
}

# A master that restores a backup answers every command with an error.
test_a_replica_whose_master_answers_an_error_is_ready_on_its_link() {
  promotable_replica
  kvrocks_replica localhost kv-1.h 40
  reply kv-1.h:6379 "info replication" "ERR restoring the db from backup"
  ready
  assert_eq 0 "$STATUS" "exit status"
}

test_a_replica_without_its_master_is_not_ready() {
  promotable_replica
  kvrocks_replica localhost kv-1.h 100 down
  ready
  assert_eq 1 "$STATUS" "exit status"
}

test_a_kvrocks_that_does_not_answer_is_not_ready() {
  promotable_replica
  hang localhost:6379
  ready
  assert_eq 1 "$STATUS" "exit status"
}

test_a_replica_no_sentinel_answers_for_is_ready_on_its_link() {
  promotable_replica
  hang localhost:26379
  hang kv-1.h:26379
  hang kv-2.h:26379
  ready
  assert_eq 0 "$STATUS" "exit status"
}
