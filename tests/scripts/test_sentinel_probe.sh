# image: sentinel
# The readiness probe of the sentinel container, on kv-0.

probe() { # Sets STATUS; what the probe printed goes to $WORLD/out.
  STATUS=0
  timeout 10 /scripts/sentinel-probe.sh >"$WORLD/out" 2>&1 || STATUS=$?
}

test_a_sentinel_that_answers_is_ready_and_says_nothing() {
  reply localhost:26379 "ping" "PONG"
  probe
  assert_eq 0 "$STATUS" "exit status"
  assert_eq "" "$(cat "$WORLD/out")" "output"
}

# Kubernetes only shows what the probe printed: an empty line told nothing.
test_a_stalled_sentinel_says_it_gave_no_reply() {
  hang localhost:26379
  probe
  assert_eq 1 "$STATUS" "exit status"
  grep -q -F "not ready: Sentinel answers PING with [no reply within 3 s]" "$WORLD/out" ||
    fail "no reason given; the probe printed: $(cat "$WORLD/out")"
}

test_a_sentinel_that_refuses_the_password_says_so() {
  reply localhost:26379 "ping" "NOAUTH Authentication required."
  probe
  assert_eq 1 "$STATUS" "exit status"
  grep -q -F "not ready: Sentinel answers PING with [NOAUTH Authentication required.]" "$WORLD/out" ||
    fail "no reason given; the probe printed: $(cat "$WORLD/out")"
}
