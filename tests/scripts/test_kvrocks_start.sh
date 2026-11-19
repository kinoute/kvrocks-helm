# image: kvrocks
# The role kv-0 picks when its kvrocks container starts. The fake kvrocks binary prints it.

start() { # Prints the role kv-0 starts with.
  mkdir -p /etc/kvrocks /var/lib/kvrocks/sentinel
  printf 'port 6379\n' >/etc/kvrocks/kvrocks.conf
  timeout 30 /scripts/kvrocks-start.sh 2>/dev/null
}

saved_view() { # $1: master, $2: config epoch
  mkdir -p /var/lib/kvrocks/sentinel
  printf 'sentinel monitor kvrocks %s 6379 2\nsentinel config-epoch kvrocks %s\n' "$1" "$2" \
    >/var/lib/kvrocks/sentinel/sentinel.conf
}

with_data() {
  mkdir -p /var/lib/kvrocks/db
  touch /var/lib/kvrocks/db/CURRENT
}

clean_volume() {
  rm -rf /var/lib/kvrocks/db /var/lib/kvrocks/sentinel /var/lib/kvrocks/conf
}

with_archived_log() {
  mkdir -p /var/lib/kvrocks/db/archive
  touch /var/lib/kvrocks/db/archive/000010.log
}

assert_log_history_kept() {
  [ -f /var/lib/kvrocks/db/archive/000010.log ] || fail "the archived log should be kept"
  if grep -q '^rocksdb.wal_' /var/lib/kvrocks/conf/kvrocks.conf; then
    fail "archiving should stay on"
  fi
}

# Replayed by an empty replica, the history would publish the hellos of the old Sentinels again.
test_a_restored_volume_drops_its_log_history() {
  clean_volume
  with_data
  with_archived_log
  assert_eq "master" "$(start)" "role"
  [ ! -e /var/lib/kvrocks/db/archive ] || fail "the archived log should be gone"
  grep -qx 'rocksdb.wal_ttl_seconds 0' /var/lib/kvrocks/conf/kvrocks.conf ||
    fail "the log replayed at startup must not be archived"
  grep -qx 'rocksdb.wal_size_limit_mb 0' /var/lib/kvrocks/conf/kvrocks.conf ||
    fail "the log replayed at startup must not be archived"
}

test_a_volume_with_a_sentinel_conf_keeps_its_log_history() {
  clean_volume
  with_data
  with_archived_log
  saved_view kv-0.h 5
  assert_eq "master" "$(start)" "role"
  assert_log_history_kept
}

test_a_standalone_kvrocks_keeps_its_log_history() {
  clean_volume
  with_data
  with_archived_log
  KVROCKS_ARCHITECTURE=standalone start >/dev/null
  assert_log_history_kept
}

test_follows_the_master_the_peer_sentinels_name() {
  clean_volume
  with_data
  sentinel_names kv-1.h kv-2.h 3
  sentinel_names kv-2.h kv-2.h 3
  assert_eq "replica of kv-2.h" "$(start)" "role"
}

test_a_newer_saved_view_wins_over_outdated_peers() {
  clean_volume
  with_data
  saved_view kv-0.h 5
  sentinel_names kv-1.h kv-1.h 3
  sentinel_names kv-2.h kv-1.h 3
  assert_eq "master" "$(start)" "role"
}

test_newer_peers_win_over_an_outdated_saved_view() {
  clean_volume
  with_data
  saved_view kv-0.h 3
  sentinel_names kv-1.h kv-1.h 5
  assert_eq "replica of kv-1.h" "$(start)" "role"
}

test_on_a_first_install_pod_0_is_the_first_master() {
  clean_volume
  kvrocks_replica kv-1.h kv-0.h 0
  kvrocks_replica kv-2.h kv-0.h 0
  reply kv-1.h:6379 "info replication" "role:slave
master_host:kv-0.h
master_repl_offset:0"
  reply kv-2.h:6379 "info replication" "role:slave
master_host:kv-0.h
master_repl_offset:0"
  assert_eq "master" "$(start)" "role"
}

test_an_empty_volume_never_becomes_master_while_a_peer_holds_data() {
  clean_volume
  saved_view kv-0.h 4
  reply kv-1.h:6379 "info replication" "role:slave
master_host:kv-0.h
master_repl_offset:5000"
  STATUS=0
  POD_NAME=kv-0 timeout 5 /scripts/kvrocks-start.sh >"$WORLD/out" 2>&1 || STATUS=$?
  assert_eq 124 "$STATUS" "it must still be waiting"
  grep -q "empty volume: waiting" "$WORLD/out" || fail "expected it to wait for a failover"
}
