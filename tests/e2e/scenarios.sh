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
EMPTY_POD_HEAD_START_SECONDS=180
DNS_OUTAGE_SECONDS=60
# An HAProxy pod started without cluster DNS must route within this delay once DNS answers.
HAPROXY_ROUTES_AFTER_DNS_SECONDS=30
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
# How long node_upgrade keeps each node out, as if it were being upgraded.
NODE_UPGRADE_SECONDS=${NODE_UPGRADE_SECONDS:-30}
# The oldest Kvrocks the chart supports in replication mode, upgraded by kvrocks_upgrade.
KVROCKS_UPGRADE_FROM=${KVROCKS_UPGRADE_FROM:-2.16.0}
# Size of the data large_dataset writes, and how long it may take per GiB, generously.
E2E_DATASET_GIB=${E2E_DATASET_GIB:-1}
DATASET_SECONDS_PER_GIB=900
# A replica must be back in sync on the whole dataset within this delay, volume lost or not.
LARGE_DATASET_TIMEOUT_SECONDS=${LARGE_DATASET_TIMEOUT_SECONDS:-3600}

scenario_install() {
  local first_install=""
  helm status "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1 || first_install=yes
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if [ "$E2E_TLS" = 1 ]; then
    create_tls_secrets
  fi
  helm upgrade --install "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    "${HELM_VALUES[@]}" >/dev/null
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
  local master other demoted_after report lost
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
  # The lost writes are those the old master kept for itself: to rejoin, it had to copy the
  # whole database again. It is the one full sync the scenarios are sure of. Not counted,
  # Kvrocks has reworded its log, and every check that nothing was copied again passes
  # without looking.
  lost=$(jq -r '.lost' <<<"$report")
  if [ "$lost" -gt 0 ]; then
    [ "$(pod_full_syncs "$master")" -ge 1 ] ||
      fail "plain_sentinel_failover: the old master lost $lost writes, yet its log shows no full sync"
  fi
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

# A Kubernetes upgrade, as a managed node pool runs it without a spare node: each node in
# turn is cordoned, drained, kept out for a while, then given back. With one Kvrocks pod per
# node, the drained pod has nowhere else to go: the release runs on the others until its node
# comes back, and the PodDisruptionBudget holds the next drain until then. Everything on the
# node is evicted except the load generator: it measures, it is not under test.
scenario_node_upgrade() {
  local node report
  start_load nodeupgrade
  for node in $(worker_nodes); do
    printf '    node_upgrade: draining %s at %s UTC, master on pod %s\n' \
      "$node" "$(date -u +%H:%M:%S)" "$(current_master)"
    kubectl cordon "$node" >/dev/null
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
      --pod-selector='app!=loadgen' --timeout=600s >/dev/null ||
      fail "node_upgrade: could not drain $node"
    sleep "$NODE_UPGRADE_SECONDS"
    kubectl uncordon "$node" >/dev/null
    wait_healthy
    printf '    node_upgrade: %s back and healthy at %s UTC, master on pod %s\n' \
      "$node" "$(date -u +%H:%M:%S)" "$(current_master)"
  done
  # Every Kvrocks container is new: any full sync they logged happened during the upgrade.
  [ "$(count_full_syncs)" = "0" ] ||
    fail "node_upgrade: a replica copied the whole database again"
  report=$(finish_load nodeupgrade)
  assert_report node_upgrade "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
}

# A Kvrocks upgrade, done as the README says: the master first moves to pod 0, which the
# rolling update restarts last, so that no replica ever runs older than its master. A
# downgrade is not supported, so the release is reinstalled on the older version first.
scenario_kvrocks_upgrade() {
  local target_version ordinal version report
  target_version=$(kvrocks_image | sed 's/.*://')
  remove_release
  helm install "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    "${HELM_VALUES[@]}" --set "image.tag=$KVROCKS_UPGRADE_FROM" >/dev/null
  k rollout status "statefulset/$FULLNAME" --timeout=600s >/dev/null ||
    fail "kvrocks_upgrade: Kvrocks $KVROCKS_UPGRADE_FROM did not start"
  wait_healthy

  k exec "$(pod_name "$(current_master)")" -c kvrocks -- \
    /scripts/kvrocks-switchover.sh --to "$(pod_name 0)" >/dev/null ||
    fail "kvrocks_upgrade: could not move the master to pod 0"
  wait_healthy
  [ "$(current_master)" = "0" ] || fail "kvrocks_upgrade: pod 0 should be the master"

  start_load kvrocksupgrade
  helm upgrade "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    "${HELM_VALUES[@]}" >/dev/null
  k rollout status "statefulset/$FULLNAME" --timeout=600s >/dev/null ||
    fail "kvrocks_upgrade: the rollout to Kvrocks $target_version did not finish"
  sleep "$LOAD_AFTER_FAILURE_SECONDS"
  wait_healthy
  for ordinal in $(ordinals); do
    version=$(kv_exec "$ordinal" kvrocks "kv_cli localhost info server | tr -d '\\r' | sed -n 's/^kvrocks_version://p'")
    [ "$version" = "$target_version" ] ||
      fail "kvrocks_upgrade: pod $ordinal runs Kvrocks $version, not $target_version"
  done
  # Every container is new: any full sync they logged happened during this rollout.
  [ "$(count_full_syncs)" = "0" ] ||
    fail "kvrocks_upgrade: a replica copied the whole database again"
  report=$(finish_load kvrocksupgrade)
  assert_report kvrocks_upgrade "$report" "$NO_LOSS" "$MAX_PLANNED_WRITE_GAP_SECONDS"
  printf '    kvrocks_upgrade: every pod moved from Kvrocks %s to %s\n' \
    "$KVROCKS_UPGRADE_FROM" "$target_version"
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
  helm upgrade "$RELEASE" "$chart" --namespace "$NAMESPACE" "${HELM_VALUES[@]}" >/dev/null
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
    "${HELM_VALUES[@]}" >/dev/null
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

# An HAProxy pod that starts while cluster DNS is down knows the address of no pod, and
# routes nowhere. It must wait, alive, and find the master as soon as DNS answers again. A
# start that hangs on name lookups fails the liveness probe: Kubernetes then restarts the
# pod over and over, each time after a longer wait, and DNS may be back long before it is.
scenario_haproxy_starts_without_dns() {
  local selector="app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=haproxy"
  local old_pod new_pod restarts dns_back
  old_pod=$(k get pods -l "$selector" -o name | head -n 1)
  stop_cluster_dns
  k delete "$old_pod" >/dev/null
  sleep "$DNS_OUTAGE_SECONDS"
  restore_cluster_dns
  dns_back=$SECONDS
  k rollout status "deployment/$FULLNAME-haproxy" \
    --timeout="${HAPROXY_ROUTES_AFTER_DNS_SECONDS}s" >/dev/null ||
    fail "haproxy_starts_without_dns: the new pod still routes nowhere ${HAPROXY_ROUTES_AFTER_DNS_SECONDS}s after DNS came back"
  printf '    haproxy_starts_without_dns: the new pod routed %ss after DNS came back\n' \
    $((SECONDS - dns_back))
  new_pod=$(k get pods -l "$selector" --sort-by=.metadata.creationTimestamp -o name | tail -n 1)
  restarts=$(k get "$new_pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  [ "$restarts" = "0" ] ||
    fail "haproxy_starts_without_dns: the new pod was restarted $restarts times while DNS was down"
  wait_healthy
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
  # Only Kind provisions a volume faster than Sentinel fails over: on real storage, the pod
  # starts after the failover, as a replica, and there is nothing to guard against.
  startup_log=$(k logs "$(pod_name "$master")" -c kvrocks)
  if ! grep -q 'empty volume: waiting' <<<"$startup_log"; then
    [ -n "$E2E_CONTEXT" ] ||
      fail "master_volume_loss: the pod came back after the failover, the guard was not exercised"
    printf '    master_volume_loss: the new volume came after the failover, nothing to guard\n'
  fi
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
  write_keys afterfailover "$OUTAGE_KEYS"
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
  local first_node deadline
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
  # The empty pod starts alone, before any peer can tell it who holds the data. The peers
  # only come back once it is seen holding back: a new volume and a cold start take long.
  deadline=$((SECONDS + EMPTY_POD_HEAD_START_SECONDS))
  until grep -q 'empty volume: waiting' <<<"$(k logs "$(pod_name 0)" -c kvrocks 2>/dev/null)"; do
    [ "$SECONDS" -lt "$deadline" ] ||
      fail "empty_first_pod_after_outage: the empty pod is not holding back"
    sleep 2
  done
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
  if k run intruder --image="$LOADGEN_IMAGE" --image-pull-policy="$LOADGEN_PULL_POLICY" --restart=Never \
    --attach --quiet --command -- python -c \
    "import socket; socket.create_connection(('$FULLNAME', 6379), timeout=5)" >/dev/null 2>&1; then
    fail "network_policy: a pod that is not an allowed client reached the write endpoint"
  fi
  printf '    network_policy: a pod without the client label is shut out\n'

  helm upgrade "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    "${HELM_VALUES[@]}" >/dev/null
  wait_healthy
}

# The migration path from a standalone Kvrocks: its data sits on the volume that pod 0 of a
# new release claims, and the replicas copy it from there.
scenario_install_from_existing_data() {
  local ns="$NAMESPACE-seed" seed_release=seed seed_fullname=seed-kvrocks ordinal found acked
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
      # Ready once Kvrocks answers, not as soon as the container starts: on a busy node, the
      # first writes of the seed were refused.
      readinessProbe:
        exec:
          command: ["sh", "-c", "MALLOC_CONF= redis-cli ping | grep -q PONG"]
        periodSeconds: 1
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
  acked=$(kubectl -n "$ns" exec standalone -- sh -c \
    "seq 1 $OUTAGE_KEYS | sed 's/.*/SET seed-$RUN_ID:& &/' | MALLOC_CONF= redis-cli | grep -c '^OK$' || true")
  [ "$acked" = "$OUTAGE_KEYS" ] ||
    fail "install_from_existing_data: only $acked of the $OUTAGE_KEYS seed writes were acknowledged"
  kubectl -n "$ns" delete pod standalone --wait=true >/dev/null

  helm install "$seed_release" "$REPO_ROOT/helm/kvrocks" --namespace "$ns" \
    --values "$E2E_DIR/values.yaml" --set haproxy.replicaCount=1 >/dev/null
  kubectl -n "$ns" rollout status "statefulset/$seed_fullname" --timeout=600s >/dev/null ||
    fail "install_from_existing_data: the pods did not become ready"
  for ordinal in $(ordinals); do
    found=$(kubectl -n "$ns" exec "$seed_fullname-$ordinal" -c kvrocks -- sh -c \
      ". /scripts/common.sh; seq 1 $OUTAGE_KEYS | sed 's/.*/EXISTS seed-$RUN_ID:&/' | MALLOC_CONF= redis-cli -p 6379 | grep -c '^1'")
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
  # Inside the pod, on the port in clear: the write endpoint is covered by helm_test.
  cli="REDISCLI_AUTH=\$KVROCKS_PASSWORD redis-cli -h localhost -p \$KVROCKS_PORT"
  helm upgrade --install solo "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    "${HELM_VALUES[@]}" --set architecture=standalone >/dev/null
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

# Fills the cluster with data shaped like a production workload, then measures
# what its size costs: the disk of each pod, the return of a replica that lost its volume,
# and the restart of a pod on a full volume. Reports numbers, asserts no threshold on them.
# An empty replica does not always copy the files of the master: while the master still holds
# its whole write-ahead log, the replica replays it instead. Each measure says which it was.
scenario_large_dataset() {
  local master replica started write_timeout
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
      args: ["--host=$FULLNAME", "--gigabytes=$E2E_DATASET_GIB", "--seed=$RUN_ID"]
      env:
        - name: KVROCKS_PASSWORD
          value: "$(password)"
        - name: KVROCKS_TLS
          value: "$E2E_TLS"
$(client_mounts)
EOF
  # The size may be a fraction of a GiB: bash has no floating point.
  write_timeout=$(awk -v gib="$E2E_DATASET_GIB" -v per="$DATASET_SECONDS_PER_GIB" \
    'BEGIN { print int(gib * per) + 60 }')
  k wait --for=jsonpath='{.status.phase}'=Succeeded pod/dataset --timeout="${write_timeout}s" \
    >/dev/null || fail "large_dataset: the dataset was not written: $(k logs dataset --tail=5 2>&1)"
  printf '    large_dataset: written %s\n' "$(k logs dataset | tail -n 1)"
  wait_healthy
  print_disk_usage

  master=$(current_master)
  replica=$(((master + 1) % REPLICAS))
  k delete pvc "data-$(pod_name "$replica")" --wait=false >/dev/null
  k delete pod "$(pod_name "$replica")" --force --grace-period=0 >/dev/null 2>&1
  started=$SECONDS
  wait_healthy_within "$LARGE_DATASET_TIMEOUT_SECONDS"
  printf '    large_dataset: a replica that lost its volume was back in sync after %ss, by %s\n' \
    $((SECONDS - started)) "$(resync_path "$replica")"

  k delete pod "$(pod_name "$replica")" >/dev/null
  started=$SECONDS
  wait_healthy_within "$LARGE_DATASET_TIMEOUT_SECONDS"
  printf '    large_dataset: a replica restarted on its full volume was back in sync after %ss, by %s\n' \
    $((SECONDS - started)) "$(resync_path "$replica")"
  print_disk_usage
}

# Only the clients the CA vouches for get in, only over TLS, and the port in clear stays
# inside the release.
scenario_tls_clients() {
  local answer
  if [ "$E2E_TLS" != 1 ]; then
    printf '    tls_clients: skipped, the scenarios run without TLS\n'
    return 0
  fi
  ensure_client_pod
  # Refused clients make the client fail: `|| true` keeps `set -e` from ending the run.
  answer=$(client_cli "\$CLI ping") || true
  [ "$answer" = "PONG" ] || fail "tls_clients: a client with a valid certificate was refused: $answer"
  answer=$(client_cli "valkey-cli -h $FULLNAME -p 6379 --tls --cacert /tls/ca.crt ping 2>&1") || true
  [ "$answer" != "PONG" ] || fail "tls_clients: a client without a certificate got in"
  answer=$(client_cli "valkey-cli -h $FULLNAME -p 6379 --tls --cacert /tls/ca.crt --cert /rogue/tls.crt --key /rogue/tls.key ping 2>&1") || true
  [ "$answer" != "PONG" ] || fail "tls_clients: a client certificate from another CA got in"
  answer=$(client_cli "timeout 5 valkey-cli -h $FULLNAME -p 6379 ping 2>&1") || true
  [ "$answer" != "PONG" ] || fail "tls_clients: a client in clear got in"
  answer=$(client_cli "timeout 5 valkey-cli -h $(pod_fqdn 0) -p $INTERNAL_PORT ping 2>&1") || true
  [ "$answer" != "PONG" ] || fail "tls_clients: the port in clear answers outside the release"
  printf '    tls_clients: only clients with a certificate from the CA, over TLS, get in\n'
}

# TLS turned on for a release that runs without it, as the README says to: the port in clear
# stays where the pods already find each other, and TLS gets a port of its own on the pods.
# The Services keep theirs, so the clients keep their address. With the port in clear moved
# instead, the first pod restarted would look for its master where no other pod listens
# yet, never become ready, and stop the rolling update there.
scenario_tls_enabled_later() {
  local plain_port=6379 tls_port=6380
  create_tls_secrets
  # The client mounts the certificates when it starts, and may be older than they are.
  k delete pod "$CLIENT_POD" --ignore-not-found >/dev/null
  remove_release
  helm install "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    "${HELM_VALUES[@]}" --set tls.enabled=false >/dev/null
  k rollout status "statefulset/$FULLNAME" --timeout=600s >/dev/null ||
    fail "tls_enabled_later: the release without TLS did not start"
  wait_healthy
  E2E_TLS=0 write_keys tlslater "$OUTAGE_KEYS"

  helm upgrade "$RELEASE" "$REPO_ROOT/helm/kvrocks" --namespace "$NAMESPACE" \
    "${HELM_VALUES[@]}" --values "$E2E_DIR/values-tls.yaml" \
    --set "port=$tls_port" --set "tls.internalPort=$plain_port" >/dev/null
  k rollout status "statefulset/$FULLNAME" --timeout=600s >/dev/null ||
    fail "tls_enabled_later: the rollout did not finish"
  k rollout status "deployment/$FULLNAME-haproxy" --timeout=300s >/dev/null ||
    fail "tls_enabled_later: the rollout of HAProxy did not finish"
  wait_healthy
  # Every container is new: any full sync they logged happened during this rollout.
  [ "$(count_full_syncs)" = "0" ] ||
    fail "tls_enabled_later: a replica copied the whole database again"
  E2E_TLS=1 assert_keys_everywhere tls_enabled_later tlslater "$OUTAGE_KEYS"
  E2E_TLS=1 INTERNAL_PORT=$plain_port scenario_tls_clients

  # Back to the release the other scenarios expect. Its port in clear is another one, the
  # very change a running release cannot take: it starts again from nothing.
  remove_release
  scenario_install
}

scenario_helm_test() {
  local output
  output=$(helm test "$RELEASE" --namespace "$NAMESPACE" 2>&1) || fail "helm_test: helm test failed"
  # `helm test` also succeeds when the chart ships no test at all.
  grep -q "$FULLNAME-test-write" <<<"$output" || fail "helm_test: the write test did not run"
  printf '    helm_test: the write test ran and passed\n'
}
