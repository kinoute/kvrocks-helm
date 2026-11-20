#!/usr/bin/env bash
# Helpers of the end-to-end scenarios. Sourced by run.sh.
# shellcheck disable=SC2034  # the settings below are used by run.sh and scenarios.sh

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
E2E_DIR="$REPO_ROOT/tests/e2e"

CLUSTER_NAME=${CLUSTER_NAME:-kvrocks-e2e}
# E2E_CONTEXT runs the scenarios on an existing cluster instead of Kind: only those that leave
# the nodes and the rest of the cluster alone, in a namespace of their own (see run.sh).
E2E_CONTEXT=${E2E_CONTEXT:-}
USER_KUBECONFIG=${KUBECONFIG:-}
RELEASE=kv
FULLNAME="$RELEASE-kvrocks"
REPLICAS=3
HAPROXY_REPLICAS=2
# A kubeconfig of its own, with a single cluster in it: these tests can never reach another.
if [ -n "$E2E_CONTEXT" ]; then
  export KUBECONFIG="$REPO_ROOT/.e2e/kubeconfig-$E2E_CONTEXT"
  NAMESPACE=${E2E_NAMESPACE:-kvrocks-ha-test}
  # Built and pushed by the CI. The tag of a branch moves, hence the pull at every start.
  LOADGEN_IMAGE=${LOADGEN_IMAGE:-ghcr.io/kinoute/kvrocks-e2e-loadgen:latest}
  LOADGEN_PULL_POLICY=Always
else
  export KUBECONFIG="$REPO_ROOT/.e2e/kubeconfig"
  NAMESPACE=kv
  LOADGEN_IMAGE=kvrocks-e2e-loadgen:dev
  LOADGEN_PULL_POLICY=Never
fi
# Part of every key: a run on a kept cluster must not find the keys of an earlier run.
RUN_ID=$(date +%s)

# The scenarios run with TLS in front of Kvrocks and client certificates required, as in
# production, unless E2E_TLS=0.
E2E_TLS=${E2E_TLS:-1}
HELM_VALUES=(--values "$E2E_DIR/values.yaml")
# The port of the traffic inside the release: replication, Sentinel, the checks. TLS moves it
# off the client port.
INTERNAL_PORT=6379
if [ "$E2E_TLS" = 1 ]; then
  HELM_VALUES+=(--values "$E2E_DIR/values-tls.yaml")
  INTERNAL_PORT=6666
fi
if [ -n "$E2E_CONTEXT" ]; then
  HELM_VALUES+=(--values "$E2E_DIR/values-cluster.yaml"
    --set "persistence.size=${E2E_VOLUME_SIZE:-10Gi}")
fi
# The certificates name the services of one namespace.
CERTS_DIR="$REPO_ROOT/.e2e/certs/$NAMESPACE"
CLIENT_POD=kv-client

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
  # The run stops here anyway. Under errexit, the first diagnostic that fails, such as the
  # logs of a pod on a dead node, would cut all the others short.
  set +e
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
    # For 30 s, a Sentinel in TILT neither votes a master down nor runs a failover. On Kind,
    # a stall of the Docker VM puts every Sentinel in TILT at once: a scenario started then
    # would measure that wait, not the chart.
    [ "$(sentinel_tilt "$ordinal")" = 0 ] || return 1
  done
}

wait_healthy() {
  wait_healthy_within "$HEALTHY_TIMEOUT_SECONDS"
}

wait_healthy_within() { # $1: seconds
  local deadline=$((SECONDS + $1))
  until is_healthy; do
    [ "$SECONDS" -lt "$deadline" ] || fail "cluster not healthy after $1s"
    sleep 2
  done
}

# What each pod's data takes on its volume.
print_disk_usage() {
  local ordinal
  for ordinal in $(ordinals); do
    printf '    pod %s: %s MiB on its volume\n' "$ordinal" \
      "$(k exec "$(pod_name "$ordinal")" -c kvrocks -- du -sm /var/lib/kvrocks | awk '{ print $1 }')"
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
  local ordinal pod container
  k get pods -o wide 2>&1 | cut -c1-130
  kubectl get nodes -o wide 2>&1 | cut -c1-130
  # Why containers restarted, and what they said last.
  for pod in $(k get pods -l "app.kubernetes.io/instance=$RELEASE" -o name 2>/dev/null); do
    k get "$pod" -o jsonpath='{range .status.initContainerStatuses[*]}{.name} restarts={.restartCount} last={.lastState.terminated.reason}/{.lastState.terminated.exitCode} ready={.ready}{"\n"}{end}{range .status.containerStatuses[*]}{.name} restarts={.restartCount} last={.lastState.terminated.reason}/{.lastState.terminated.exitCode} ready={.ready}{"\n"}{end}' 2>/dev/null |
      sed "s|^|  ${pod#pod/}: |"
    for container in $(k get "$pod" -o jsonpath='{range .status.initContainerStatuses[?(@.restartCount>0)]}{.name} {end}{range .status.containerStatuses[?(@.restartCount>0)]}{.name} {end}' 2>/dev/null); do
      k logs "$pod" -c "$container" --previous --tail=8 2>&1 | sed "s|^|    ${pod#pod/}/$container (previous): |" | cut -c1-200
    done
    # A container stuck unready says why in its current log, not in the previous one.
    for container in $(k get "$pod" -o jsonpath='{range .status.initContainerStatuses[?(@.ready==false)]}{.name} {end}{range .status.containerStatuses[?(@.ready==false)]}{.name} {end}' 2>/dev/null); do
      k logs "$pod" -c "$container" --tail=8 2>&1 | sed "s|^|    ${pod#pod/}/$container (current): |" | cut -c1-200
    done
  done
  # Cluster DNS and the pod network, which restarted nodes have to bring back.
  kubectl -n kube-system get pods -o wide 2>&1 | grep -E 'coredns|kindnet|kube-proxy' | cut -c1-130
  for pod in $(kubectl -n kube-system get pods -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==false)]}{.metadata.name} {end}' 2>/dev/null); do
    kubectl -n kube-system logs "$pod" --previous --tail=6 2>&1 | sed "s|^|    $pod (previous): |" | cut -c1-200
  done
  k get events --sort-by=.lastTimestamp 2>&1 | grep -E 'Unhealthy|BackOff|Killing|Failed' | tail -12 | cut -c1-200
  # A handover that gave up leaves a FailedPreStopHook event, and its reason on the volume:
  # hook output never reaches the container logs.
  k get events --field-selector reason=FailedPreStopHook -o custom-columns=POD:.involvedObject.name,MESSAGE:.message --no-headers 2>&1 | tail -5
  for ordinal in $(ordinals); do
    k exec "$(pod_name "$ordinal")" -c kvrocks -- tail -n 6 /var/lib/kvrocks/handover.log 2>/dev/null |
      sed "s|^|    $(pod_name "$ordinal")/handover.log: |" | cut -c1-220
  done
  # What each Sentinel did last. One in TILT mode stalls a handover without a word.
  for ordinal in $(ordinals); do
    k logs "$(pod_name "$ordinal")" -c sentinel --tail=200 2>/dev/null |
      grep -E 'tilt|failover|switch-master|sdown|odown' | tail -n 8 |
      sed "s|^|    $(pod_name "$ordinal")/sentinel: |" | cut -c1-200
  done
  for ordinal in $(ordinals); do
    printf 'pod %s: role=%s master_link=%s sentinel_master=%s sentinel_tilt=%s\n' "$ordinal" \
      "$(kv_exec "$ordinal" kvrocks 'kv_info_field localhost role')" \
      "$(kv_exec "$ordinal" kvrocks 'kv_info_field localhost master_link_status')" \
      "$(kv_exec "$ordinal" sentinel 'sentinel_master localhost')" \
      "$(sentinel_tilt "$ordinal")"
  done
}

# Pods that stand for clients run on the control-plane node, so that taking a worker down
# never takes them too. Their label lets them through the NetworkPolicy scenario.
client_pod_spec() {
  # On Kind, the clients stay off the workers, which the scenarios kill.
  if [ -z "$E2E_CONTEXT" ]; then
    cat <<EOF
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
EOF
  fi
  cat <<EOF
  volumes:
    - name: client-tls
      secret:
        secretName: kv-client-tls
        optional: true
    - name: rogue-tls
      secret:
        secretName: kv-rogue-client-tls
        optional: true
EOF
}

client_mounts() {
  cat <<EOF
      volumeMounts:
        - name: client-tls
          mountPath: /tls
          readOnly: true
        - name: rogue-tls
          mountPath: /rogue
          readOnly: true
EOF
}

start_load() { # $1: name of the load, also its key prefix
  # A finished load of an earlier run keeps its name.
  k delete pod "load-$1" --ignore-not-found >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: load-$1
  labels:
    app: loadgen
spec:
  restartPolicy: Never
$(client_pod_spec)
  containers:
    - name: load
      image: $LOADGEN_IMAGE
      imagePullPolicy: $LOADGEN_PULL_POLICY
      args:
        - --host=$FULLNAME
        - --key-prefix=$1-$RUN_ID
        - --settle-seconds=$LOAD_SETTLE_SECONDS
        - --pod-host=$(pod_fqdn 0)
        - --pod-host=$(pod_fqdn 1)
        - --pod-host=$(pod_fqdn 2)
      env:
        - name: KVROCKS_PASSWORD
          value: "$(password)"
        - name: KVROCKS_TLS
          value: "$E2E_TLS"
$(client_mounts)
EOF
  k wait --for=condition=Ready "pod/load-$1" --timeout=120s >/dev/null
  sleep "$LOAD_WARMUP_SECONDS"
}

# A long-lived client next to the cluster: valkey-cli with the test client certificate.
ensure_client_pod() {
  k get pod "$CLIENT_POD" >/dev/null 2>&1 && return 0
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $CLIENT_POD
  labels:
    app: loadgen
spec:
$(client_pod_spec)
  containers:
    - name: cli
      image: $(sentinel_image)
      command: ["sleep", "infinity"]
      env:
        - name: REDISCLI_AUTH
          value: "$(password)"
$(client_mounts)
EOF
  k wait --for=condition=Ready "pod/$CLIENT_POD" --timeout=120s >/dev/null
}

# valkey-cli against the write endpoint, as an application would connect.
client_cli() { # $1: a shell snippet that may use $CLI, the client command line
  local tls_args=""
  if [ "$E2E_TLS" = 1 ]; then
    tls_args="--tls --cacert /tls/ca.crt --cert /tls/tls.crt --key /tls/tls.key"
  fi
  ensure_client_pod
  k exec "$CLIENT_POD" -- sh -c "CLI='valkey-cli -h $FULLNAME -p 6379 $tls_args'; $1" 2>/dev/null
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
  local acked lost gap worst_pod read_only
  acked=$(jq -r '.acked' <<<"$2")
  lost=$(jq -r '.lost' <<<"$2")
  gap=$(jq -r '.longest_write_gap_seconds' <<<"$2")
  # A pod that never answered counts as missing everything.
  worst_pod=$(jq -r --argjson acked "$acked" '[.missing_by_pod[] // $acked] | max' <<<"$2")

  printf '    %s: acked=%s lost=%s worst_pod_missing=%s longest_write_gap=%ss errors=%s\n' \
    "$1" "$acked" "$lost" "$worst_pod" "$gap" "$(jq -c '.errors' <<<"$2")"
  # When the writes stopped, in UTC, to be matched with the steps the scenario printed.
  jq -r '.write_gaps // [] | .[] | "      no write from \(.at) UTC for \(.seconds)s"' <<<"$2"

  [ "$acked" -gt 0 ] || fail "$1: no write was acknowledged"
  [ "$lost" != "null" ] || fail "$1: the write endpoint never answered the verification"
  [ "$lost" -le "$3" ] || fail "$1: lost $lost acknowledged writes (allowed: $3)"
  # Every pod must hold exactly what the master holds: more or fewer keys means they diverged.
  jq -e '.lost as $lost | all(.missing_by_pod[]; . == $lost)' <<<"$2" >/dev/null ||
    fail "$1: the pods diverged from the master: $(jq -c '.missing_by_pod' <<<"$2")"
  awk -v gap="$gap" -v max="$4" 'BEGIN { exit !(gap <= max) }' ||
    fail "$1: writes were interrupted for ${gap}s (allowed: ${4}s)"
  # What may lose nothing, a handover above all, must not refuse writes as read-only either:
  # most clients do not retry that error, and redis-py keeps the connection after it.
  if [ "$3" = "$NO_LOSS" ]; then
    read_only=$(jq '.errors.ReadOnlyError // 0' <<<"$2")
    [ "$read_only" = 0 ] || fail "$1: $read_only writes were refused as read-only"
  fi
}

# Writes keys <prefix>:1..<count> through the write endpoint, as a client would.
# Waits for the endpoint to take writes first, and fails unless every write was acknowledged.
write_keys() { # $1: prefix, $2: count
  local deadline=$((SECONDS + HEALTHY_TIMEOUT_SECONDS)) replies acked failures other_errors
  until [ "$(client_cli "\$CLI set $1:probe 1")" = "OK" ]; do
    [ "$SECONDS" -lt "$deadline" ] || fail "the write endpoint never took a write"
    sleep 1
  done
  while true; do
    # Connection errors come on stderr: kept with the replies, to tell what went wrong.
    replies=$(client_cli "seq 1 $2 | sed 's/.*/SET $1-$RUN_ID:& &/' | \$CLI 2>&1")
    acked=$(grep -c -x OK <<<"$replies" || true)
    [ "$acked" != "$2" ] || return 0
    failures=$(grep -v -x OK <<<"$replies" | sort | uniq -c)
    # After a node is lost, the Service still lists the HAProxy pod it ran for up to a minute.
    # valkey-cli then drops each command whose connection lands on that pod, where a client
    # would retry it: the batch is sent again until the Service drops that pod. That is safe,
    # the same SET twice changes nothing. Any other reply fails at once.
    other_errors=$(grep -v -x OK <<<"$replies" | grep -v '^Could not connect to ' || true)
    [ -z "$other_errors" ] || break
    [ "$SECONDS" -lt "$deadline" ] || break
    printf '    only %s of the %s writes of %s were acknowledged, sending them again:\n%s\n' \
      "$acked" "$2" "$1" "$failures"
  done
  fail "only $acked of the $2 writes of $1 were acknowledged; the other replies were:
$failures"
}

# How long writing a dataset may take per GiB, generously.
DATASET_SECONDS_PER_GIB=900

# Writes data shaped like a production workload through the write endpoint.
write_dataset() { # $1: scenario, $2: size in GiB
  local write_timeout
  k delete pod dataset --ignore-not-found >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dataset
  labels:
    app: loadgen
spec:
  restartPolicy: Never
$(client_pod_spec)
  containers:
    - name: dataset
      image: $LOADGEN_IMAGE
      imagePullPolicy: $LOADGEN_PULL_POLICY
      command: ["/app/.venv/bin/python", "/app/dataset.py"]
      args: ["--host=$FULLNAME", "--gigabytes=$2", "--seed=$RUN_ID"]
      env:
        - name: KVROCKS_PASSWORD
          value: "$(password)"
        - name: KVROCKS_TLS
          value: "$E2E_TLS"
$(client_mounts)
EOF
  # The size may be a fraction of a GiB: bash has no floating point.
  write_timeout=$(awk -v gib="$2" -v per="$DATASET_SECONDS_PER_GIB" \
    'BEGIN { print int(gib * per) + 60 }')
  k wait --for=jsonpath='{.status.phase}'=Succeeded pod/dataset --timeout="${write_timeout}s" \
    >/dev/null || fail "$1: the dataset was not written: $(k logs dataset --tail=5 2>&1)"
  printf '    %s: written %s\n' "$1" "$(k logs dataset | tail -n 1)"
}

# Counts how many of the keys <prefix>:1..<count> a host holds: the write endpoint through
# the client pod, a Kvrocks pod on its port in clear, from inside the release.
count_keys() { # $1: host, $2: prefix, $3: count
  local query="seq 1 $3 | sed 's/.*/EXISTS $2-$RUN_ID:&/'"
  if [ "$1" = "$FULLNAME" ]; then
    client_cli "$query | \$CLI | grep -c '^1'"
  else
    kv_exec 0 sentinel "$query | redis-cli -h $1 -p \$KVROCKS_PORT | grep -c '^1'"
  fi
}

assert_keys_everywhere() { # $1: scenario, $2: prefix, $3: count
  local host found
  for host in "$FULLNAME" $(for ordinal in $(ordinals); do pod_fqdn "$ordinal"; done); do
    # grep -c fails when it counts none, and so does a host that cannot be reached: without
    # the guard, the run would stop here without a word.
    found=$(count_keys "$host" "$2" "$3") || true
    [ "$found" = "$3" ] || fail "$1: $host holds ${found:-no answer} of the $3 keys"
  done
  printf '    %s: all %s keys are on the write endpoint and on every pod\n' "$1" "$3"
}

# Network cuts, as iptables rules on the nodes. Undone by heal_partition.
PARTITION_RULES=()

drop_traffic() { # $1: node, then the iptables match
  local node=$1
  shift
  docker exec "$node" iptables -I FORWARD "$@" -j DROP
  PARTITION_RULES+=("$node $* -j DROP")
}

heal_partition() {
  local rule node
  [ "${#PARTITION_RULES[@]}" -gt 0 ] || return 0
  for rule in "${PARTITION_RULES[@]}"; do
    node=${rule%% *}
    # shellcheck disable=SC2086  # the rule is a list of iptables arguments
    docker exec "$node" iptables -D FORWARD ${rule#* } 2>/dev/null || true
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
  drop_traffic "$(node_of "$1")" -s "$(pod_ip "$1")" -d "$(pod_ip "$2")" -p tcp --dport "$INTERNAL_PORT"
}

# The same cut, answered with a TCP reset instead of silence. Kvrocks takes two minutes to
# notice a link that went silent, and is back a second after one that was refused.
refuse_replication() { # $1: replica ordinal, $2: master ordinal
  local node rule
  node=$(node_of "$1")
  rule="-s $(pod_ip "$1") -d $(pod_ip "$2") -p tcp --dport $INTERNAL_PORT -j REJECT --reject-with tcp-reset"
  # shellcheck disable=SC2086  # the rule is a list of iptables arguments
  docker exec "$node" iptables -I FORWARD $rule
  PARTITION_RULES+=("$node $rule")
}

# Long enough to put Sentinel in TILT mode: it enters it after a stall of more than 2 s.
SENTINEL_STALL_SECONDS=3

# Freezes the Sentinel of a pod for a moment, as a busy node would.
stall_sentinel() { # $1: ordinal
  k exec "$(pod_name "$1")" -c sentinel -- sh -c "
    pid=\$(pidof redis-sentinel)
    kill -STOP \"\$pid\"
    sleep $SENTINEL_STALL_SECONDS
    kill -CONT \"\$pid\""
}

sentinel_tilt() { # $1: ordinal. Prints 1 while the Sentinel of that pod is in TILT mode.
  kv_exec "$1" sentinel 'sentinel_cli localhost info sentinel | tr -d "\r" | sed -n "s/^sentinel_tilt://p"'
}

# Full syncs logged by the running Kvrocks container of a pod. A restarted container starts
# from 0.
pod_full_syncs() { # $1: ordinal
  k logs "$(pod_name "$1")" -c kvrocks 2>/dev/null | grep -c 'fullsync was finish' || true
}

# How the running Kvrocks container of a replica caught up with its master: by copying its
# files, or by replaying its write-ahead log, from the first write when the replica was empty.
resync_path() { # $1: ordinal
  if [ "$(pod_full_syncs "$1")" -ge 1 ]; then
    printf 'a full sync'
  else
    printf 'replaying the write-ahead log of the master'
  fi
}

count_full_syncs() {
  local ordinal total=0
  for ordinal in $(ordinals); do
    total=$((total + $(pod_full_syncs "$ordinal")))
  done
  printf '%s\n' "$total"
}

# How many writes the load acknowledges in that many seconds, on average.
writes_in_seconds() { # $1: JSON report, $2: seconds
  jq -r --argjson seconds "$2" '(.acked / .duration_seconds * $seconds) | ceil' <<<"$1"
}

# Kind nodes are containers on this Docker network, created with a subnet of our own so that
# a node can get its address back: Docker hands a restarted container the lowest free
# address, and a node that comes back under another one confuses its kubelet and its pods.
NODE_NETWORK=kvrocks-e2e
NODE_SUBNET=172.31.250.0/24
declare -A NODE_ADDRESSES=()

kill_nodes() { # node names
  local node
  for node in "$@"; do
    NODE_ADDRESSES[$node]=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NODE_NETWORK\").IPAddress}}" "$node")
  done
  docker kill "$@" >/dev/null
}

start_nodes() { # node names
  local node address
  for node in "$@"; do
    # Reconnecting a running node would drop its routes to the pods of the other nodes, and
    # with them cluster DNS when CoreDNS runs there.
    [ "$(docker inspect -f '{{.State.Running}}' "$node")" = true ] && continue
    address=${NODE_ADDRESSES[$node]:-}
    if [ -n "$address" ]; then
      docker network disconnect "$NODE_NETWORK" "$node" >/dev/null 2>&1 || true
      docker network connect --ip "$address" "$NODE_NETWORK" "$node"
    fi
    docker start "$node" >/dev/null
  done
}

worker_nodes() {
  kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | sed 's|node/||'
}

# The master the Sentinel of a pod names, once it answers at all.
wait_for_sentinel_answer() { # $1: ordinal
  local deadline=$((SECONDS + HEALTHY_TIMEOUT_SECONDS)) named=""
  while [ -z "$named" ] && [ "$SECONDS" -lt "$deadline" ]; do
    named=$(kv_exec "$1" sentinel 'sentinel_master localhost' || true)
    [ -n "$named" ] || sleep 2
  done
  printf '%s\n' "$named"
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

count_failed_hooks() {
  k get events --field-selector reason=FailedPreStopHook --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# Cluster DNS, stopped by scaling CoreDNS to zero. Restored by restore_cluster_dns, and by
# the cleanup of run.sh if a scenario fails halfway.
COREDNS_REPLICAS=""

stop_cluster_dns() {
  COREDNS_REPLICAS=$(kubectl -n kube-system get deployment coredns -o jsonpath='{.spec.replicas}')
  kubectl -n kube-system scale deployment coredns --replicas=0 >/dev/null
  kubectl -n kube-system wait --for=delete pod -l k8s-app=kube-dns --timeout=60s >/dev/null
}

restore_cluster_dns() {
  [ -n "$COREDNS_REPLICAS" ] || return 0
  kubectl -n kube-system scale deployment coredns --replicas="$COREDNS_REPLICAS" >/dev/null
  kubectl -n kube-system rollout status deployment coredns --timeout=120s >/dev/null
  COREDNS_REPLICAS=""
}

# Cluster DNS stays on the control plane, with the clients: the scenarios take workers down,
# some for minutes, and only the scenarios about DNS are meant to take cluster DNS with them.
# Kind starts CoreDNS there, but once dns_outage scaled it back up, the scheduler spread it
# over the workers, and the pods of a worker restarted alone found no DNS at all. kubeadm's
# CoreDNS already tolerates the control plane's taint.
pin_cluster_dns_to_control_plane() {
  kubectl -n kube-system patch deployment coredns --patch \
    '{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"affinity":{"nodeAffinity":null},"topologySpreadConstraints":null}}}}' >/dev/null
  kubectl -n kube-system rollout status deployment coredns --timeout=180s >/dev/null
}

# One replica of cluster DNS on the control plane and one on the given worker, as the
# scheduler of a real cluster spreads them. Undone by pin_cluster_dns_to_control_plane.
# A spread constraint rather than a required anti-affinity: the anti-affinity of the pods
# left on the control plane would keep the pods pinned back there from ever starting.
spread_cluster_dns_to() { # $1: worker node
  local control_plane patch
  control_plane=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
  patch=$(jq -n --arg control_plane "$control_plane" --arg worker "$1" '{spec: {template: {spec: {
    nodeSelector: null,
    affinity: {nodeAffinity: {requiredDuringSchedulingIgnoredDuringExecution: {nodeSelectorTerms: [
      {matchExpressions: [{key: "kubernetes.io/hostname", operator: "In", values: [$control_plane, $worker]}]}]}}},
    topologySpreadConstraints: [{maxSkew: 1, topologyKey: "kubernetes.io/hostname",
      whenUnsatisfiable: "DoNotSchedule", labelSelector: {matchLabels: {"k8s-app": "kube-dns"}},
      matchLabelKeys: ["pod-template-hash"]}]}}}}')
  kubectl -n kube-system patch deployment coredns --patch "$patch" >/dev/null
  kubectl -n kube-system rollout status deployment coredns --timeout=180s >/dev/null
}

# Ready pods of one component of the release: "<ready>/<all>".
ready_pods() { # $1: component (kvrocks, haproxy)
  k get pods -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=$1" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
    awk '$1 == "True" { ready++ } { all++ } END { printf "%d/%d", ready, all }'
}

# The rotation of the README: a new password in the Secret, then every pod deleted at once.
rotate_password() { # $1: new password
  helm upgrade "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" --reuse-values \
    --set-string "auth.password=$1" >/dev/null
  k delete pod -l "app.kubernetes.io/instance=$RELEASE" --wait=false >/dev/null
  # The client pod reads the password when it starts.
  k delete pod "$CLIENT_POD" --ignore-not-found --wait=true >/dev/null
  k wait --for=delete pod -l "app.kubernetes.io/instance=$RELEASE" --timeout=180s >/dev/null 2>&1 || true
  wait_healthy
}

# How many times the Sentinels of the given pods entered TILT mode since a moment.
sentinel_tilts_since() { # $1: time (RFC 3339), then ordinals
  local since=$1 ordinal
  shift
  for ordinal in "$@"; do
    k logs "$(pod_name "$ordinal")" -c sentinel --since-time="$since" 2>/dev/null | grep -c '+tilt' || true
  done | awk '{ total += $1 } END { print total + 0 }'
}

# Uninstalls the release and deletes its volumes: the next install starts from nothing.
remove_release() {
  local ordinal
  helm uninstall "$RELEASE" --namespace "$NAMESPACE" --wait >/dev/null
  for ordinal in $(ordinals); do
    k delete pvc "data-$(pod_name "$ordinal")" --ignore-not-found --wait=true >/dev/null
  done
}

# The Kvrocks image the chart deploys.
kvrocks_image() {
  helm template "$RELEASE" "$REPO_ROOT/helm/kvrocks" --values "$E2E_DIR/values.yaml" |
    awk '$1 == "image:" && $2 ~ /\/apache\/kvrocks:/ { print $2; exit }'
}

# The Sentinel image the chart deploys, which carries valkey-cli.
sentinel_image() {
  helm template "$RELEASE" "$REPO_ROOT/helm/kvrocks" --values "$E2E_DIR/values.yaml" |
    awk '$1 == "image:" && $2 ~ /\/valkey\/valkey:/ { print $2; exit }'
}

# Test certificates with the profile of the production ones: a server certificate for the
# names clients use (not the pods'), usable as server only; a client certificate; and a
# client certificate from another CA, which must be refused.
# The extensions are those of a real PKI: Python 3.13 and later verify strictly by default,
# and refuse a certificate without an Authority Key Identifier or a CA without key usage.
make_test_certificates() {
  local san
  mkdir -p "$CERTS_DIR"
  [ -f "$CERTS_DIR/server.crt" ] && return 0
  (
    cd "$CERTS_DIR" || exit 1
    issue() { # $1: name, $2: CA, $3: extensions
      openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$1" 2>/dev/null
      printf '%s\n' "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature,keyEncipherment" \
        "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid,issuer" "$3" >"$1.ext"
      openssl x509 -req -in "$1.csr" -CA "$2.crt" -CAkey "$2.key" -CAcreateserial -out "$1.crt" \
        -days 30 -extfile "$1.ext" 2>/dev/null
    }
    for ca in ca rogue-ca; do
      openssl req -x509 -newkey rsa:2048 -nodes -keyout "$ca.key" -out "$ca.crt" -days 30 \
        -subj "/CN=$ca" -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash" 2>/dev/null
    done
    san="DNS:localhost"
    for service in "$FULLNAME" "$FULLNAME-read" solo-kvrocks; do
      san="$san,DNS:$service,DNS:$service.$NAMESPACE,DNS:$service.$NAMESPACE.svc,DNS:$service.$NAMESPACE.svc.cluster.local"
    done
    issue server ca "subjectAltName=$san
extendedKeyUsage=serverAuth"
    issue client ca "extendedKeyUsage=clientAuth"
    issue rogue-client rogue-ca "extendedKeyUsage=clientAuth"
  )
}

create_tls_secrets() {
  make_test_certificates
  k create secret tls kv-kvrocks-tls --cert="$CERTS_DIR/server.crt" --key="$CERTS_DIR/server.key" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k create secret generic kv-kvrocks-ca --from-file=ca.crt="$CERTS_DIR/ca.crt" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  # The client Secrets also carry the CA, to verify the server.
  k create secret generic kv-client-tls --from-file=tls.crt="$CERTS_DIR/client.crt" \
    --from-file=tls.key="$CERTS_DIR/client.key" --from-file=ca.crt="$CERTS_DIR/ca.crt" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k create secret generic kv-rogue-client-tls --from-file=tls.crt="$CERTS_DIR/rogue-client.crt" \
    --from-file=tls.key="$CERTS_DIR/rogue-client.key" --from-file=ca.crt="$CERTS_DIR/ca.crt" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
}
