# image: kvrocks
# Behaviours of the real Kvrocks of the image that the README documents as Caveats. A test
# that starts failing after a Kvrocks bump means upstream changed: update the Caveat.

KVROCKS=/usr/bin/kvrocks
CLI=/usr/bin/redis-cli
PORT=6399

real_cli() {
  MALLOC_CONF='' "$CLI" -p "$PORT" "$@" 2>/dev/null
}

start_real_kvrocks() {
  mkdir -p "$WORLD/kvrocks"
  MALLOC_CONF='' "$KVROCKS" --bind 127.0.0.1 --port "$PORT" --dir "$WORLD/kvrocks" \
    >"$WORLD/kvrocks.log" 2>&1 &
  KVROCKS_PID=$!
  attempts=0
  until [ "$(real_cli ping)" = PONG ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 50 ] || fail "Kvrocks did not start; its log was:
$(cat "$WORLD/kvrocks.log")"
    sleep 0.1
  done
}

# CLIENT PAUSE WRITE holds commands flagged as writes, and EXEC is not one. An EXEC that
# arrives during the pause runs its queued writes, which stop at the pause, and the
# transaction is thrown away: EXEC answers an empty array and nothing is ever written.
test_kvrocks_drops_a_transaction_whose_exec_comes_during_a_write_pause() {
  start_real_kvrocks
  {
    echo MULTI
    echo "SET a 1"
    echo "SET b 2"
    sleep 1.5
    echo EXEC
    sleep 0.5
  } | MALLOC_CONF='' "$CLI" --no-raw -p "$PORT" >"$WORLD/transaction" 2>/dev/null &
  sleep 0.5
  assert_eq OK "$(real_cli client pause 2000 write)" "pause"
  wait $!
  sleep 1.5
  exec_reply=$(sed -n 4p "$WORLD/transaction")
  a=$(real_cli get a)
  b=$(real_cli get b)
  kill "$KVROCKS_PID"
  assert_eq "(empty array)" "$exec_reply" "reply of EXEC"
  assert_eq "" "$a$b" "keys written by the transaction, once the pause is over"
}
