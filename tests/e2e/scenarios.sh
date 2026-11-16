#!/usr/bin/env bash
# The end-to-end scenarios. Each one breaks something under write load, then checks how
# many acknowledged writes were lost and for how long writes were interrupted.

# A planned change (handover, rolling update) must lose nothing.
NO_LOSS=0
# Replication is asynchronous: when the master dies, the writes it acknowledged in its
# last instants and had not sent yet are lost. This bounds how many.
MAX_LOSS_ON_CRASH=${MAX_LOSS_ON_CRASH:-50}
MAX_PLANNED_WRITE_GAP_SECONDS=${MAX_PLANNED_WRITE_GAP_SECONDS:-10}
# Sentinel waits 10 s before declaring the master down, then promotes a replica.
MAX_CRASH_WRITE_GAP_SECONDS=${MAX_CRASH_WRITE_GAP_SECONDS:-40}
OUTAGE_KEYS=2000
EMPTY_POD_HEAD_START_SECONDS=40
DNS_OUTAGE_SECONDS=60
# An isolated master must stop taking writes within this delay.
FENCE_DEADLINE_SECONDS=5
# The writes an isolated master may still acknowledge, in seconds of load: what it takes
# in before it is fenced, with room for the load being uneven.
MAX_FENCE_SECONDS=10
# The chart's default sentinel.downAfterMilliseconds.
SENTINEL_DOWN_AFTER_SECONDS=10
# Left alone, Sentinel takes about ten seconds to demote a former master.
MAX_DEMOTION_SECONDS=5
# About one second of writes: the time Sentinel needs between promoting and switching.
MAX_LOSS_ON_PLAIN_FAILOVER=${MAX_LOSS_ON_PLAIN_FAILOVER:-30000}

scenario_install() {
  local first_install=""
  helm status "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1 || first_install=yes
  helm upgrade --install "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    --create-namespace --values "$E2E_DIR/values.yaml" >/dev/null
  k rollout status "statefulset/$FULLNAME" --timeout=600s >/dev/null
  wait_healthy
  if [ -n "$first_install" ]; then
    [ "$(current_master)" = "0" ] || fail "install: pod 0 should be the first master"
  fi
}

# An operator hands the master role over by hand.
scenario_switchover() {
  local master report full_syncs_before
  master=$(current_master)
  full_syncs_before=$(count_full_syncs)
  start_load switchover
  k exec "$(pod_name "$master")" -c kvrocks -- /scripts/kvrocks-switchover.sh ||
    fail "switchover: the handover script failed"
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  wait_healthy
  [ "$(current_master)" != "$master" ] || fail "switchover: the master did not change"
  # Every pod holds the same data after a handover: copying it all again would make each
  # rolling update as costly as the size of the volume.
  [ "$(count_full_syncs)" = "$full_syncs_before" ] ||
    fail "switchover: the handover made a replica copy the whole database again"
  report=$(finish_load switchover)
  assert_report switchover "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

# A replica is alive but no longer receives the replication stream. Sentinel picks the
# replica to promote from offsets it read up to ten seconds earlier, so it could pick this
# one and lose what it misses. The handover must refuse, and leave the master in place.
scenario_switchover_with_lagging_replica() {
  local master lagging report
  master=$(current_master)
  lagging=$(((master + 1) % REPLICAS))
  start_load lagging
  cut_replication "$lagging" "$master"
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  if k exec "$(pod_name "$master")" -c kvrocks -- /scripts/kvrocks-switchover.sh; then
    fail "switchover_with_lagging_replica: the handover went ahead with a replica behind"
  fi
  [ "$(current_master)" = "$master" ] ||
    fail "switchover_with_lagging_replica: the master changed"
  heal_partition
  wait_healthy
  report=$(finish_load lagging)
  assert_report switchover_with_lagging_replica "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

# A replica is dead but the master still lists it: Kvrocks only drops a vanished replica
# once TCP gives up on it, minutes later. The handover must not wait for it and must
# still reach the healthy replica.
scenario_switchover_with_dead_replica() {
  local master dead node report
  master=$(current_master)
  dead=$(((master + 1) % REPLICAS))
  node=$(node_of "$dead")
  start_load deadreplica
  kill_nodes "$node"
  # Long enough for Sentinel to rule the dead replica out as a candidate.
  sleep "$SENTINEL_DOWN_AFTER_SECONDS"
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  k exec "$(pod_name "$master")" -c kvrocks -- /scripts/kvrocks-switchover.sh ||
    fail "switchover_with_dead_replica: the handover script failed"
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  start_nodes "$node"
  wait_healthy
  [ "$(current_master)" != "$master" ] || fail "switchover_with_dead_replica: the master did not change"
  report=$(finish_load deadreplica)
  assert_report switchover_with_dead_replica "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

# The master stops while a replica Sentinel could promote is behind: its preStop handover
# gives up, and keeps writes paused until the pod is gone. The failover that follows must
# promote the up-to-date replica and lose nothing.
scenario_handover_aborted_on_stop() {
  local master lagging new_master handover_log report
  master=$(current_master)
  lagging=$(((master + 1) % REPLICAS))
  start_load abortedstop
  cut_replication "$lagging" "$master"
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  k delete pod "$(pod_name "$master")" --wait=false >/dev/null
  new_master=$(wait_for_new_master "$master")
  [ "$new_master" != "$lagging" ] ||
    fail "handover_aborted_on_stop: Sentinel promoted the replica that was behind"
  heal_partition
  wait_healthy
  handover_log=$(kv_exec "$master" kvrocks "cat \$DATA_DIR/handover.log")
  grep -q 'writes stay paused until this pod stops' <<<"$handover_log" ||
    fail "handover_aborted_on_stop: the handover did not give up as expected"
  report=$(finish_load abortedstop)
  assert_report handover_aborted_on_stop "$report" "$NO_LOSS" "$MAX_CRASH_WRITE_GAP_SECONDS"
}

# Someone runs a plain SENTINEL FAILOVER instead of the handover script. Sentinel promotes
# a replica while the old master still accepts writes, so some are lost: that is what the
# handover script exists to avoid. What the chart still guarantees is that the old master
# is demoted at once, not ten seconds later, and that every pod ends up identical.
scenario_plain_sentinel_failover() {
  local master other demoted_after report
  master=$(current_master)
  other=$(((master + 1) % REPLICAS))
  start_load plainfailover
  kv_exec "$other" sentinel "sentinel_cli localhost sentinel failover \$SENTINEL_MASTER_NAME" >/dev/null
  demoted_after=$(seconds_until_replica "$master")
  [ "$demoted_after" -le "$MAX_DEMOTION_SECONDS" ] ||
    fail "plain_sentinel_failover: the old master stayed writable for ${demoted_after}s"
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  wait_healthy
  report=$(finish_load plainfailover)
  assert_report plain_sentinel_failover "$report" "$MAX_LOSS_ON_PLAIN_FAILOVER" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

# Every pod restarts in turn; the master hands over from its preStop hook.
scenario_rolling_update() {
  local report
  start_load rolling
  k rollout restart "statefulset/$FULLNAME" >/dev/null
  k rollout status "statefulset/$FULLNAME" --timeout=600s >/dev/null ||
    fail "rolling_update: the rollout did not finish"
  wait_healthy
  # Every container is new: any full sync they logged happened during this rollout.
  [ "$(count_full_syncs)" = "0" ] ||
    fail "rolling_update: a replica copied the whole database again"
  report=$(finish_load rolling)
  assert_report rolling_update "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

# A helm upgrade that changes the scripts. Their ConfigMap is replaced while the pods of the
# previous revision still have to run their preStop hook from it.
scenario_upgrade_with_new_scripts() {
  local chart failed_hooks_before report
  chart="$REPO_ROOT/.e2e/chart-upgrade"
  rm -rf "$chart"
  cp -R "$REPO_ROOT/helm/kvrocks" "$chart"
  printf '# upgrade %s\n' "$RUN_ID" >>"$chart/files/scripts/common.sh"
  failed_hooks_before=$(count_failed_hooks)
  start_load upgrade
  helm upgrade "$RELEASE" "$chart" --namespace "$NAMESPACE" --values "$E2E_DIR/values.yaml" >/dev/null
  k rollout status "statefulset/$FULLNAME" --timeout=600s >/dev/null ||
    fail "upgrade_with_new_scripts: the rollout did not finish"
  wait_healthy
  [ "$(count_failed_hooks)" = "$failed_hooks_before" ] ||
    fail "upgrade_with_new_scripts: a preStop handover failed"
  [ "$(count_full_syncs)" = "0" ] ||
    fail "upgrade_with_new_scripts: a replica copied the whole database again"
  report=$(finish_load upgrade)
  assert_report upgrade_with_new_scripts "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"

  # Back to the chart itself for the scenarios that follow.
  helm upgrade "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    --values "$E2E_DIR/values.yaml" >/dev/null
  k rollout status "statefulset/$FULLNAME" --timeout=600s >/dev/null
  wait_healthy
}

# The node of the master is drained: the pod is evicted and hands over on its way out.
scenario_drain() {
  local master node report
  master=$(current_master)
  node=$(node_of "$master")
  start_load drain
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=180s >/dev/null ||
    fail "drain: could not drain $node"
  wait_for_new_master "$master" >/dev/null
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  kubectl uncordon "$node" >/dev/null
  wait_healthy
  report=$(finish_load drain)
  assert_report drain "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

scenario_haproxy_restart() {
  local report
  start_load haproxy
  k rollout restart "deployment/$FULLNAME-haproxy" >/dev/null
  k rollout status "deployment/$FULLNAME-haproxy" --timeout=300s >/dev/null ||
    fail "haproxy_restart: the rollout did not finish"
  wait_healthy
  report=$(finish_load haproxy)
  assert_report haproxy_restart "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

# The master pod dies without warning. Its replacement comes back on the same volume.
scenario_master_pod_crash() {
  local master report
  master=$(current_master)
  start_load podcrash
  k delete pod "$(pod_name "$master")" --force --grace-period=0 >/dev/null 2>&1
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  wait_healthy
  report=$(finish_load podcrash)
  assert_report master_pod_crash "$report" "$MAX_LOSS_ON_CRASH" "$MAX_CRASH_WRITE_GAP_SECONDS"
}

# The node of the master goes dark, then comes back: the former master must rejoin as a replica.
scenario_master_node_failure() {
  local master node new_master report
  master=$(current_master)
  node=$(node_of "$master")
  start_load nodefail
  kill_nodes "$node"
  new_master=$(wait_for_new_master "$master")
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  start_nodes "$node"
  wait_healthy
  [ "$(current_master)" = "$new_master" ] || fail "master_node_failure: the master changed again"
  report=$(finish_load nodefail)
  assert_report master_node_failure "$report" "$MAX_LOSS_ON_CRASH" "$MAX_CRASH_WRITE_GAP_SECONDS"
}

# The master pod is cut off from the network while it keeps running.
scenario_master_partition() {
  local master report
  master=$(current_master)
  start_load partition
  partition_pod "$master"
  wait_for_new_master "$master" >/dev/null
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  heal_partition
  wait_healthy
  report=$(finish_load partition)
  assert_report master_partition "$report" "$MAX_LOSS_ON_CRASH" "$MAX_CRASH_WRITE_GAP_SECONDS"
}

# The master is cut off from the other Kvrocks pods, but HAProxy still reaches it, so the
# connections already open keep writing to it. Without fencing, it would acknowledge
# writes for the whole partition, and all of them are lost when it rejoins as a replica.
scenario_master_isolated_from_peers() {
  local master new_master probe report
  master=$(current_master)
  start_load isolated
  isolate_from_peers "$master"
  sleep "$FENCE_DEADLINE_SECONDS"
  # A fenced master holds the write until the timeout: no answer at all is the expected outcome.
  probe=$(kv_exec "$master" kvrocks 'CLI_TIMEOUT_SECONDS=2; kv_cli localhost set fence:probe 1' || true)
  [ "$probe" != "OK" ] ||
    fail "master_isolated_from_peers: the isolated master still accepts writes"
  new_master=$(wait_for_new_master "$master")
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  heal_partition
  wait_healthy
  [ "$(current_master)" = "$new_master" ] ||
    fail "master_isolated_from_peers: the master changed again"
  report=$(finish_load isolated)
  assert_report master_isolated_from_peers "$report" \
    "$(writes_in_seconds "$report" "$MAX_FENCE_SECONDS")" "$MAX_CRASH_WRITE_GAP_SECONDS"
}

# Cluster DNS stops answering for a minute. Nothing else is wrong, so nothing may change:
# same master, no write paused, nothing lost.
scenario_dns_outage() {
  local master since report
  master=$(current_master)
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_load dnsoutage
  stop_cluster_dns
  sleep "$DNS_OUTAGE_SECONDS"
  restore_cluster_dns
  wait_healthy
  [ "$(current_master)" = "$master" ] || fail "dns_outage: the master changed"
  ! k logs "$(pod_name "$master")" -c fence --since-time="$since" | grep -q 'writes paused' ||
    fail "dns_outage: the fencing paused a healthy master"
  report=$(finish_load dnsoutage)
  assert_report dns_outage "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

# A replica loses its disk: it must come back empty and copy everything again.
scenario_replica_volume_loss() {
  local master replica report
  master=$(current_master)
  replica=$(((master + 1) % REPLICAS))
  start_load replicavolume
  k delete pvc "data-$(pod_name "$replica")" --wait=false >/dev/null
  k delete pod "$(pod_name "$replica")" --force --grace-period=0 >/dev/null 2>&1
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  wait_healthy
  [ "$(current_master)" = "$master" ] || fail "replica_volume_loss: the master should not change"
  report=$(finish_load replicavolume)
  assert_report replica_volume_loss "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

# The master loses its disk and restarts before Sentinel noticed. Starting as an empty
# master would wipe every replica: it must wait to be failed over, then rejoin as a replica.
scenario_master_volume_loss() {
  local master report startup_log
  master=$(current_master)
  start_load mastervolume
  k delete pvc "data-$(pod_name "$master")" --wait=false >/dev/null
  k delete pod "$(pod_name "$master")" --force --grace-period=0 >/dev/null 2>&1
  wait_for_new_master "$master" >/dev/null
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  wait_healthy
  # Without this, a pod that came back after the failover would pass without proving anything.
  startup_log=$(k logs "$(pod_name "$master")" -c kvrocks)
  grep -q 'empty volume: waiting' <<<"$startup_log" ||
    fail "master_volume_loss: the pod came back after the failover, the guard was not exercised"
  report=$(finish_load mastervolume)
  assert_report master_volume_loss "$report" "$MAX_LOSS_ON_CRASH" "$MAX_CRASH_WRITE_GAP_SECONDS"
}

# Every node dies at once, like a power cut. Nothing replicated before may be missing after.
scenario_full_outage() {
  local nodes
  nodes=$(worker_nodes)
  write_keys outage "$OUTAGE_KEYS"
  wait_healthy
  assert_keys_everywhere full_outage_before outage "$OUTAGE_KEYS"

  # shellcheck disable=SC2086  # one argument per node
  kill_nodes $nodes
  # shellcheck disable=SC2086
  start_nodes $nodes
  wait_healthy
  assert_keys_everywhere full_outage_after outage "$OUTAGE_KEYS"
}

# A former master that missed a failover comes back first after a full outage. Its own
# Sentinel still names it as master; the pods that hold the newer data must not follow it,
# or they would replace their data with its older copy.
scenario_stale_master_starts_first() {
  local old_master old_node new_master named
  old_master=$(current_master)
  old_node=$(node_of "$old_master")
  kill_nodes "$old_node"
  new_master=$(wait_for_new_master "$old_master")
  write_keys afterfailover "$OUTAGE_KEYS" "$new_master"
  # Lets the remaining replica receive them: only replicated data survives an outage.
  sleep "$LOAD_AFTER_FAILURE_SECONDS"

  # shellcheck disable=SC2046  # one argument per node
  kill_nodes $(worker_nodes | grep -v -x "$old_node")
  start_nodes "$old_node"
  wait_until_pod_answers "$old_master"
  # The scenario only means something if the outdated Sentinel is there to mislead the others.
  # It restarts with its pod, possibly after Kvrocks already answers: give it some time.
  named=$(wait_for_sentinel_answer "$old_master")
  [ "$named" = "$(pod_fqdn "$old_master")" ] ||
    fail "stale_master_starts_first: the outdated Sentinel names [$named], not the old master"
  # shellcheck disable=SC2046
  start_nodes $(worker_nodes)
  wait_healthy
  [ "$(current_master)" != "$old_master" ] ||
    fail "stale_master_starts_first: the pod that missed the failover is master again"
  assert_keys_everywhere stale_master_starts_first afterfailover "$OUTAGE_KEYS"
}

# Pod 0 was the master, lost its disk during a full outage and comes back first, empty.
# It must not start as an empty master: its peers would copy that emptiness.
scenario_empty_first_pod_after_outage() {
  local first_node startup_log
  make_master 0
  write_keys beforeloss "$OUTAGE_KEYS"
  wait_healthy
  assert_keys_everywhere empty_first_pod_before beforeloss "$OUTAGE_KEYS"

  first_node=$(node_of 0)
  # shellcheck disable=SC2046  # one argument per node
  kill_nodes $(worker_nodes)
  k delete pvc "data-$(pod_name 0)" --wait=false >/dev/null
  k delete pod "$(pod_name 0)" --force --grace-period=0 >/dev/null 2>&1
  start_nodes "$first_node"
  # A head start for the empty pod, alone, before any peer can tell it who holds the data.
  sleep "$EMPTY_POD_HEAD_START_SECONDS"
  startup_log=$(k logs "$(pod_name 0)" -c kvrocks)
  grep -q 'empty volume: waiting' <<<"$startup_log" ||
    fail "empty_first_pod_after_outage: the empty pod is not holding back"
  # shellcheck disable=SC2046
  start_nodes $(worker_nodes)
  wait_healthy
  assert_keys_everywhere empty_first_pod_after_outage beforeloss "$OUTAGE_KEYS"
}

# With the NetworkPolicy on, replication, Sentinel and HAProxy must keep working, an allowed
# client must get through, and any other pod must be shut out.
scenario_network_policy() {
  local master report
  helm upgrade "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" --reuse-values \
    --set networkPolicy.enabled=true \
    --set 'networkPolicy.clientsFrom[0].podSelector.matchLabels.app=loadgen' >/dev/null
  wait_healthy

  master=$(current_master)
  start_load netpol
  k exec "$(pod_name "$master")" -c kvrocks -- /scripts/kvrocks-switchover.sh ||
    fail "network_policy: the handover script failed"
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  wait_healthy
  report=$(finish_load netpol)
  assert_report network_policy "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"

  k delete pod intruder --ignore-not-found >/dev/null
  if k run intruder --image="$LOADGEN_IMAGE" --image-pull-policy=Never --restart=Never \
    --attach --quiet --command -- python -c \
    "import socket; socket.create_connection(('$FULLNAME', 6379), timeout=5)" >/dev/null 2>&1; then
    fail "network_policy: a pod that is not an allowed client reached the write endpoint"
  fi
  printf '    network_policy: a pod without the client label is shut out\n'

  helm upgrade "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    --values "$E2E_DIR/values.yaml" >/dev/null
  wait_healthy
}

# The migration path from a standalone Kvrocks: its data sits on the volume that pod 0 of a
# new release claims, and the replicas copy it from there.
scenario_install_from_existing_data() {
  local ns=kv-seed seed_release=seed seed_fullname=seed-kvrocks ordinal found
  kubectl create namespace "$ns" >/dev/null
  kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-$seed_fullname-0
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: standalone
spec:
  securityContext:
    runAsUser: 999
    fsGroup: 999
  containers:
    - name: kvrocks
      image: $(kvrocks_image)
      command: ["sh", "-c", "printf 'bind 0.0.0.0\\nport 6379\\ndir /var/lib/kvrocks\\n' >/tmp/kvrocks.conf && exec kvrocks -c /tmp/kvrocks.conf"]
      volumeMounts:
        - name: data
          mountPath: /var/lib/kvrocks
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-$seed_fullname-0
EOF
  kubectl -n "$ns" wait --for=condition=Ready pod/standalone --timeout=180s >/dev/null ||
    fail "install_from_existing_data: the standalone Kvrocks did not start"
  kubectl -n "$ns" exec standalone -- sh -c \
    "seq 1 $OUTAGE_KEYS | sed 's/.*/SET seed-$RUN_ID:& &/' | MALLOC_CONF= redis-cli >/dev/null"
  kubectl -n "$ns" delete pod standalone --wait=true >/dev/null

  helm install "$seed_release" "$REPO_ROOT/helm/kvrocks" --namespace "$ns" \
    --values "$E2E_DIR/values.yaml" --set haproxy.replicaCount=1 >/dev/null
  kubectl -n "$ns" rollout status "statefulset/$seed_fullname" --timeout=600s >/dev/null ||
    fail "install_from_existing_data: the pods did not become ready"
  for ordinal in $(ordinals); do
    found=$(kubectl -n "$ns" exec "$seed_fullname-$ordinal" -c kvrocks -- sh -c \
      ". /scripts/common.sh; seq 1 $OUTAGE_KEYS | sed 's/.*/EXISTS seed-$RUN_ID:&/' | redis-cli -p 6379 | grep -c '^1'")
    [ "$found" = "$OUTAGE_KEYS" ] ||
      fail "install_from_existing_data: pod $ordinal holds $found of the $OUTAGE_KEYS keys"
  done
  [ "$(kubectl -n "$ns" exec "$seed_fullname-0" -c kvrocks -- sh -c '. /scripts/common.sh; kv_role localhost')" = "master" ] ||
    fail "install_from_existing_data: pod 0, which holds the data, should be the master"
  printf '    install_from_existing_data: all %s keys are on every pod, pod 0 is master\n' "$OUTAGE_KEYS"
  helm uninstall "$seed_release" --namespace "$ns" >/dev/null
  kubectl delete namespace "$ns" --wait=false >/dev/null
}

# The single-instance mode: no Sentinel, no HAProxy, data survives a restart of the pod.
scenario_standalone() {
  local solo=solo-kvrocks cli
  cli="REDISCLI_AUTH=\$KVROCKS_PASSWORD redis-cli -h $solo -p 6379"
  helm upgrade --install solo "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    --values "$E2E_DIR/values.yaml" --set architecture=standalone >/dev/null
  k rollout status "statefulset/$solo" --timeout=300s >/dev/null ||
    fail "standalone: the pod did not become ready"
  [ "$(k exec "$solo-0" -c kvrocks -- sh -c "$cli set standalone:key kept")" = "OK" ] ||
    fail "standalone: the write was refused"

  k delete pod "$solo-0" >/dev/null
  k rollout status "statefulset/$solo" --timeout=300s >/dev/null ||
    fail "standalone: the pod did not come back"
  [ "$(k exec "$solo-0" -c kvrocks -- sh -c "$cli get standalone:key")" = "kept" ] ||
    fail "standalone: the key did not survive the restart"
  printf '    standalone: a key written before the restart is still there\n'
  helm uninstall solo --namespace "$NAMESPACE" >/dev/null
}

scenario_helm_test() {
  local output
  output=$(helm test "$RELEASE" --namespace "$NAMESPACE" 2>&1) || fail "helm_test: helm test failed"
  # `helm test` also succeeds when the chart ships no test at all.
  grep -q "$FULLNAME-test-write" <<<"$output" || fail "helm_test: the write test did not run"
  printf '    helm_test: the write test ran and passed\n'
}
