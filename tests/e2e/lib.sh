#!/usr/bin/env bash
# Helpers of the end-to-end scenarios. Sourced by run.sh.
# shellcheck disable=SC2034  # the settings below are used by run.sh and scenarios.sh

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
E2E_DIR="$REPO_ROOT/tests/e2e"

CLUSTER_NAME=${CLUSTER_NAME:-kvrocks-e2e}
# A kubeconfig of its own: these tests can never reach another cluster.
export KUBECONFIG="$REPO_ROOT/.e2e/kubeconfig"

NAMESPACE=kv
RELEASE=kv
FULLNAME="$RELEASE-kvrocks"
REPLICAS=3
HAPROXY_REPLICAS=2
LOADGEN_IMAGE=kvrocks-e2e-loadgen:dev

HEALTHY_TIMEOUT_SECONDS=300
NEW_MASTER_TIMEOUT_SECONDS=90
# How long the load keeps running after a failure, to prove writes resumed.
LOAD_AFTER_FAILURE_SECONDS=8
LOAD_WARMUP_SECONDS=5
# Pause between the end of the load and its verification. Short: every scenario already
# waits for a healthy cluster before it stops the load.
LOAD_SETTLE_SECONDS=5
SENTINEL_INFO_PERIOD_SECONDS=10

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf 'FAILED: %s\n' "$*" >&2
  describe_cluster >&2
  exit 1
}

k() {
  kubectl -n "$NAMESPACE" "$@"
}

password() {
  k get secret "$FULLNAME" -o jsonpath='{.data.password}' | base64 -d
}

pod_name() { # $1: ordinal
  printf '%s-%s\n' "$FULLNAME" "$1"
}

pod_fqdn() { # $1: ordinal
  printf '%s-%s.%s-headless.%s.svc.cluster.local\n' "$FULLNAME" "$1" "$FULLNAME" "$NAMESPACE"
}

ordinals() {
  seq 0 $((REPLICAS - 1))
}

# Runs a shell snippet in a container, with the chart's own helpers loaded.
kv_exec() { # $1: ordinal, $2: container, $3: snippet
  k exec "$(pod_name "$1")" -c "$2" -- sh -c ". /scripts/common.sh; $3" 2>/dev/null
}

node_of() { # $1: ordinal
  k get pod "$(pod_name "$1")" -o jsonpath='{.spec.nodeName}'
}

# Ordinal of the pod every Sentinel names as master; empty unless they all agree.
current_master() {
  local ordinal master agreed=""
  for ordinal in $(ordinals); do
    master=$(kv_exec "$ordinal" sentinel 'sentinel_master localhost') || return 0
    [ -n "$master" ] || return 0
    [ -z "$agreed" ] || [ "$agreed" = "$master" ] || return 0
    agreed=$master
  done
  agreed=${agreed%%.*}
  printf '%s\n' "${agreed##*-}"
}

sentinel_sees() { # $1: ordinal, $2: field of SENTINEL MASTER
  kv_exec "$1" sentinel "sentinel_cli localhost sentinel master \$SENTINEL_MASTER_NAME" |
    paste - - | awk -v field="$2" '$1 == field { print $2 }'
}

all_pods_ready() {
  local expected=$((REPLICAS + HAPROXY_REPLICAS))
  local selector="app.kubernetes.io/instance=$RELEASE"
  [ "$(k get pods -l "$selector" --no-headers 2>/dev/null | wc -l)" -eq "$expected" ] &&
    k wait --for=condition=Ready pods -l "$selector" --timeout=1s >/dev/null 2>&1
}

follows() { # $1: replica ordinal, $2: master ordinal
  [ "$(kv_exec "$1" kvrocks 'kv_info_field localhost role')" = "slave" ] &&
    [ "$(kv_exec "$1" kvrocks 'kv_info_field localhost master_host')" = "$(pod_fqdn "$2")" ] &&
    [ "$(kv_exec "$1" kvrocks 'kv_info_field localhost master_link_status')" = "up" ]
}

# One master every Sentinel agrees on, every other pod replicating it, and no Sentinel
# that lost track of a peer or still counts one that is gone.
#
# Replication is checked on each replica, not with the master's connected_slaves: Kvrocks
# keeps counting a replica whose pod is gone until TCP gives up on it, minutes later.
is_healthy() {
  local master ordinal
  all_pods_ready || return 1
  master=$(current_master)
  [ -n "$master" ] || return 1
  [ "$(kv_exec "$master" kvrocks 'kv_info_field localhost role')" = "master" ] || return 1
  for ordinal in $(ordinals); do
    [ "$ordinal" = "$master" ] || follows "$ordinal" "$master" || return 1
    [ "$(sentinel_sees "$ordinal" num-other-sentinels)" = "$((REPLICAS - 1))" ] || return 1
    [ "$(sentinel_sees "$ordinal" num-slaves)" = "$((REPLICAS - 1))" ] || return 1
  done
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTHY_TIMEOUT_SECONDS))
  until is_healthy; do
    [ "$SECONDS" -lt "$deadline" ] || fail "cluster not healthy after ${HEALTHY_TIMEOUT_SECONDS}s"
    sleep 2
  done
}

wait_for_new_master() { # $1: ordinal of the former master. Prints the new one.
  local deadline=$((SECONDS + NEW_MASTER_TIMEOUT_SECONDS)) master
  while [ "$SECONDS" -lt "$deadline" ]; do
    master=$(majority_master "$1")
    if [ -n "$master" ] && [ "$master" != "$1" ]; then
      printf '%s\n' "$master"
      return 0
    fi
    sleep 1
  done
  fail "no new master ${NEW_MASTER_TIMEOUT_SECONDS}s after losing pod $1"
}

# Seconds until a pod reports itself as a replica.
seconds_until_replica() { # $1: ordinal
  local started=$SECONDS
  until [ "$(kv_exec "$1" kvrocks 'kv_info_field localhost role')" = "slave" ]; do
    [ $((SECONDS - started)) -lt "$NEW_MASTER_TIMEOUT_SECONDS" ] || fail "pod $1 was never demoted"
  done
  printf '%s\n' $((SECONDS - started))
}

# The master named by the Sentinels of the surviving pods (the former master's is unreachable).
majority_master() { # $1: ordinal to skip
  local ordinal master
  for ordinal in $(ordinals); do
    [ "$ordinal" = "$1" ] && continue
    master=$(kv_exec "$ordinal" sentinel 'sentinel_master localhost')
    master=${master%%.*}
    [ -n "$master" ] && printf '%s\n' "${master##*-}"
  done | sort | uniq -c | sort -rn | awk 'NR == 1 { print $2 }'
}

describe_cluster() {
  local ordinal
  k get pods -o wide 2>&1 | cut -c1-130
  # A handover that gave up leaves its reason in a FailedPreStopHook event.
  k get events --field-selector reason=FailedPreStopHook -o custom-columns=POD:.involvedObject.name,MESSAGE:.message --no-headers 2>&1 | tail -5
  for ordinal in $(ordinals); do
    printf 'pod %s: role=%s master_link=%s sentinel_master=%s\n' "$ordinal" \
      "$(kv_exec "$ordinal" kvrocks 'kv_info_field localhost role')" \
      "$(kv_exec "$ordinal" kvrocks 'kv_info_field localhost master_link_status')" \
      "$(kv_exec "$ordinal" sentinel 'sentinel_master localhost')"
  done
}

# The load runs on the control-plane node, so that taking a worker down never takes it too.
start_load() { # $1: name of the load, also its key prefix
  local overrides='{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists"}]}}'
  # A finished load of an earlier run keeps its name.
  k delete pod "load-$1" --ignore-not-found >/dev/null
  k run "load-$1" --image="$LOADGEN_IMAGE" --image-pull-policy=Never --restart=Never \
    --labels=app=loadgen --env="KVROCKS_PASSWORD=$(password)" --overrides="$overrides" -- \
    --host "$FULLNAME" --key-prefix "$1" --settle-seconds "$LOAD_SETTLE_SECONDS" \
    --pod-host "$(pod_fqdn 0)" --pod-host "$(pod_fqdn 1)" --pod-host "$(pod_fqdn 2)" >/dev/null
  k wait --for=condition=Ready "pod/load-$1" --timeout=120s >/dev/null
  sleep "$LOAD_WARMUP_SECONDS"
}

# Stops the load and prints its JSON report, once it has read every acknowledged key back.
finish_load() { # $1: name of the load
  k exec "load-$1" -- kill -TERM 1
  k wait --for=jsonpath='{.status.phase}'=Succeeded "pod/load-$1" --timeout=600s >/dev/null ||
    fail "load $1 did not finish"
  k logs "load-$1" | tail -n 1
}

# Fails unless the report shows at most the allowed loss and write outage.
assert_report() { # $1: scenario, $2: JSON report, $3: max lost writes, $4: max write gap (seconds)
  local acked lost gap worst_pod
  acked=$(jq -r '.acked' <<<"$2")
  lost=$(jq -r '.lost' <<<"$2")
  gap=$(jq -r '.longest_write_gap_seconds' <<<"$2")
  # A pod that never answered counts as missing everything.
  worst_pod=$(jq -r --argjson acked "$acked" '[.missing_by_pod[] // $acked] | max' <<<"$2")

  printf '    %s: acked=%s lost=%s worst_pod_missing=%s longest_write_gap=%ss errors=%s\n' \
    "$1" "$acked" "$lost" "$worst_pod" "$gap" "$(jq -c '.errors' <<<"$2")"

  [ "$acked" -gt 0 ] || fail "$1: no write was acknowledged"
  [ "$lost" != "null" ] || fail "$1: the write endpoint never answered the verification"
  [ "$lost" -le "$3" ] || fail "$1: lost $lost acknowledged writes (allowed: $3)"
  # Every pod must hold exactly what the master holds: more or fewer keys means they diverged.
  jq -e '.lost as $lost | all(.missing_by_pod[]; . == $lost)' <<<"$2" >/dev/null ||
    fail "$1: the pods diverged from the master: $(jq -c '.missing_by_pod' <<<"$2")"
  awk -v gap="$gap" -v max="$4" 'BEGIN { exit !(gap <= max) }' ||
    fail "$1: writes were interrupted for ${gap}s (allowed: ${4}s)"
}

# Writes keys <prefix>:1..<count> through the write endpoint, from a pod that is up.
# Waits for the endpoint to take writes first, and fails unless every write was acknowledged.
write_keys() { # $1: prefix, $2: count, $3: ordinal of the pod to run from (default 0)
  local from=${3:-0} deadline=$((SECONDS + HEALTHY_TIMEOUT_SECONDS)) acked
  until [ "$(kv_exec "$from" sentinel "redis-cli -h $FULLNAME -p \$KVROCKS_PORT set $1:probe 1")" = "OK" ]; do
    [ "$SECONDS" -lt "$deadline" ] || fail "the write endpoint never took a write"
    sleep 1
  done
  acked=$(kv_exec "$from" sentinel "seq 1 $2 | sed 's/.*/SET $1:& &/' | redis-cli -h $FULLNAME -p \$KVROCKS_PORT | grep -c '^OK$'")
  [ "$acked" = "$2" ] || fail "only $acked of the $2 writes of $1 were acknowledged"
}

# Counts how many of the keys <prefix>:1..<count> a host holds.
count_keys() { # $1: host, $2: prefix, $3: count
  kv_exec 0 sentinel "seq 1 $3 | sed 's/.*/EXISTS $2:&/' | redis-cli -h $1 -p \$KVROCKS_PORT | grep -c '^1'"
}

assert_keys_everywhere() { # $1: scenario, $2: prefix, $3: count
  local host found
  for host in "$FULLNAME" $(for ordinal in $(ordinals); do pod_fqdn "$ordinal"; done); do
    found=$(count_keys "$host" "$2" "$3")
    [ "$found" = "$3" ] || fail "$1: $host holds $found of the $3 keys"
  done
  printf '    %s: all %s keys are on the write endpoint and on every pod\n' "$1" "$3"
}

# Network cuts, as iptables rules on the nodes. Undone by heal_partition.
PARTITION_RULES=()

drop_traffic() { # $1: node, then the iptables match
  local node=$1
  shift
  docker exec "$node" iptables -I FORWARD "$@" -j DROP
  PARTITION_RULES+=("$node $*")
}

heal_partition() {
  local rule node
  [ "${#PARTITION_RULES[@]}" -gt 0 ] || return 0
  for rule in "${PARTITION_RULES[@]}"; do
    node=${rule%% *}
    # shellcheck disable=SC2086  # the match is a list of iptables arguments
    docker exec "$node" iptables -D FORWARD ${rule#* } -j DROP 2>/dev/null || true
  done
  PARTITION_RULES=()
}

pod_ip() { # $1: ordinal
  k get pod "$(pod_name "$1")" -o jsonpath='{.status.podIP}'
}

# Cuts a pod off from everything.
partition_pod() { # $1: ordinal
  local node ip
  node=$(node_of "$1")
  ip=$(pod_ip "$1")
  drop_traffic "$node" -s "$ip"
  drop_traffic "$node" -d "$ip"
}

# Cuts a pod off from the other Kvrocks pods only: HAProxy still reaches it.
isolate_from_peers() { # $1: ordinal
  local node ip ordinal peer_ip
  node=$(node_of "$1")
  ip=$(pod_ip "$1")
  for ordinal in $(ordinals); do
    [ "$ordinal" = "$1" ] && continue
    peer_ip=$(pod_ip "$ordinal")
    drop_traffic "$node" -s "$ip" -d "$peer_ip"
    drop_traffic "$node" -s "$peer_ip" -d "$ip"
  done
}

# Stops a replica from receiving the replication stream. Sentinel still reaches it and
# sees it alive, so it stays a candidate for promotion.
cut_replication() { # $1: replica ordinal, $2: master ordinal
  drop_traffic "$(node_of "$1")" -s "$(pod_ip "$1")" -d "$(pod_ip "$2")" -p tcp --dport 6379
}

# Full syncs logged by the running Kvrocks containers. A restarted container starts from 0.
count_full_syncs() {
  local ordinal count total=0
  for ordinal in $(ordinals); do
    count=$(k logs "$(pod_name "$ordinal")" -c kvrocks 2>/dev/null | grep -c 'fullsync was finish' || true)
    total=$((total + count))
  done
  printf '%s\n' "$total"
}

# How many writes the load acknowledges in that many seconds, on average.
writes_in_seconds() { # $1: JSON report, $2: seconds
  jq -r --argjson seconds "$2" '(.acked / .duration_seconds * $seconds) | ceil' <<<"$1"
}

worker_nodes() {
  kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | sed 's|node/||'
}

wait_until_pod_answers() { # $1: ordinal
  local deadline=$((SECONDS + HEALTHY_TIMEOUT_SECONDS))
  until [ -n "$(kv_exec "$1" kvrocks 'kv_info_field localhost role')" ]; do
    [ "$SECONDS" -lt "$deadline" ] || fail "Kvrocks never answered in pod $1"
    sleep 2
  done
}

# Hands the master role over to a given pod. Sentinel promotes the replica with the lowest
# priority value, and reads it from INFO every ten seconds.
make_master() { # $1: ordinal
  local master
  master=$(current_master)
  [ "$master" = "$1" ] && return 0
  kv_exec "$1" kvrocks 'kv_cli localhost config set slave-priority 1' >/dev/null
  sleep "$SENTINEL_INFO_PERIOD_SECONDS"
  k exec "$(pod_name "$master")" -c kvrocks -- /scripts/kvrocks-switchover.sh ||
    fail "could not hand the master role over to pod $1"
  kv_exec "$1" kvrocks 'kv_cli localhost config set slave-priority 100' >/dev/null
  wait_healthy
  [ "$(current_master)" = "$1" ] || fail "Sentinel did not promote pod $1"
}
