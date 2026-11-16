# image: sentinel
# Helpers shared by every script, here under busybox.

. /scripts/common.sh

test_a_view_pairs_the_master_with_its_epoch() {
  sentinel_names kv-1.h kv-2.h 7
  assert_eq "7 kv-2.h" "$(sentinel_view kv-1.h)" "view"
}

test_a_failover_completing_during_the_read_gives_no_view() {
  sentinel_names kv-1.h kv-0.h 3
  # The epoch changes between the two reads of SENTINEL MASTER.
  handler kv-1.h:26379 "sentinel master kvrocks" <<'HANDLER'
count_file="$WORLD/epoch-reads"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$count" >"$count_file"
printf 'name\nkvrocks\nip\nkv-0.h\nconfig-epoch\n%s\n' "$((count + 2))"
HANDLER
  assert_eq "" "$(sentinel_view kv-1.h)" "view"
}

test_an_error_reply_gives_no_view() {
  reply kv-1.h:26379 "sentinel get-master-addr-by-name kvrocks" "NOAUTH Authentication required."
  reply kv-1.h:26379 "sentinel master kvrocks" "NOAUTH Authentication required."
  assert_eq "" "$(sentinel_view kv-1.h)" "view"
}

test_a_pod_outside_the_statefulset_gives_no_view() {
  sentinel_names kv-1.h kv-7.h 9
  assert_eq "" "$(sentinel_view kv-1.h)" "view"
}

test_the_role_of_a_kvrocks_that_does_not_answer_is_unknown() {
  down kv-1.h:6379
  assert_eq unknown "$(kv_role kv-1.h)" "role"
}

test_the_newest_peer_view_wins() {
  sentinel_names kv-1.h kv-1.h 4
  sentinel_names kv-2.h kv-2.h 6
  assert_eq "6 kv-2.h" "$(newest_peer_view)" "view"
}
