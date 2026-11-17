#!/usr/bin/env bash
# End-to-end tests of the chart on a local Kind cluster.
#
# Usage: tests/e2e/run.sh [scenario ...]    every scenario, in order, by default
#        KEEP_CLUSTER=1 tests/e2e/run.sh    keeps the cluster afterwards, to look around
#        E2E_CONTEXT=<context> tests/e2e/run.sh
#                                           runs on an existing cluster instead, in its own
#                                           namespace, the scenarios of CLUSTER_SCENARIOS only
#
# Needs docker, kind, kubectl, helm and jq.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scenarios.sh
source "$E2E_DIR/scenarios.sh"

ALL_SCENARIOS=(
  install
  switchover
  switchover_with_dead_replica
  switchover_with_lagging_replica
  handover_aborted_on_stop
  plain_sentinel_failover
  rolling_update
  upgrade_with_new_scripts
  kvrocks_upgrade
  drain
  node_upgrade
  haproxy_restart
  master_pod_crash
  master_node_failure
  master_partition
  master_isolated_from_peers
  dns_outage
  replica_volume_loss
  master_volume_loss
  full_outage
  stale_master_starts_first
  empty_first_pod_after_outage
  tls_clients
  tls_enabled_later
  network_policy
  install_from_existing_data
  standalone
  helm_test
)

# What an existing cluster can take: no scenario that kills a node, cuts the network with
# iptables on a node, drains a node or stops cluster DNS.
CLUSTER_SCENARIOS=(
  install
  tls_clients
  tls_enabled_later
  switchover
  plain_sentinel_failover
  rolling_update
  upgrade_with_new_scripts
  kvrocks_upgrade
  haproxy_restart
  master_pod_crash
  replica_volume_loss
  master_volume_loss
  network_policy
  install_from_existing_data
  standalone
  helm_test
)

ensure_cluster() {
  mkdir -p "$(dirname "$KUBECONFIG")"
  if [ -n "$E2E_CONTEXT" ]; then
    # The credentials of that one context, readable by the user only.
    (umask 077 && KUBECONFIG=$USER_KUBECONFIG kubectl config view --minify --flatten \
      --context "$E2E_CONTEXT" >"$KUBECONFIG")
    kubectl get --raw /version >/dev/null || fail "cannot reach the cluster of $E2E_CONTEXT"
    return 0
  fi
  if kind get clusters 2>/dev/null | grep -q -x "$CLUSTER_NAME"; then
    kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
  else
    docker network inspect "$NODE_NETWORK" >/dev/null 2>&1 ||
      docker network create --driver bridge --subnet "$NODE_SUBNET" \
        --opt com.docker.network.bridge.enable_ip_masquerade=true "$NODE_NETWORK" >/dev/null
    KIND_EXPERIMENTAL_DOCKER_NETWORK=$NODE_NETWORK \
      kind create cluster --name "$CLUSTER_NAME" --config "$E2E_DIR/kind.yaml" --kubeconfig "$KUBECONFIG"
  fi
  kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
  # Cluster DNS stays on the control plane, with the clients: the scenarios take workers
  # down, some for minutes, and only dns_outage is meant to take cluster DNS with them. Kind
  # starts CoreDNS there, but once dns_outage scaled it back up, the scheduler spread it over
  # the workers, and the pods of a worker restarted alone found no DNS at all. kubeadm's
  # CoreDNS already tolerates the control plane's taint.
  kubectl -n kube-system patch deployment coredns --patch \
    '{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""}}}}}' >/dev/null
  kubectl -n kube-system rollout status deployment coredns --timeout=120s >/dev/null
}

# Only the load generator is built here. The chart's own images are pulled by the nodes,
# as on a real cluster.
load_images() {
  # An existing cluster pulls the load generator from its registry.
  [ -z "$E2E_CONTEXT" ] || return 0
  # Without provenance: its attestation manifest makes `kind load` fail on a missing digest.
  docker build --quiet --provenance=false --tag "$LOADGEN_IMAGE" "$E2E_DIR/loadgen" >/dev/null
  kind load docker-image "$LOADGEN_IMAGE" --name "$CLUSTER_NAME" >/dev/null 2>&1 ||
    fail "could not load $LOADGEN_IMAGE into the cluster"
}

# Checked before anything is created, so that a refused run leaves nothing to clean up.
if [ -n "$E2E_CONTEXT" ]; then
  scenarios=("${@:-${CLUSTER_SCENARIOS[@]}}")
  for scenario in "${scenarios[@]}"; do
    # Only when named: large_dataset, and node_upgrade, which drains every node in turn.
    case " ${CLUSTER_SCENARIOS[*]} large_dataset node_upgrade " in
      *" $scenario "*) ;;
      *)
        printf '%s touches the nodes or the whole cluster: Kind only\n' "$scenario" >&2
        exit 2
        ;;
    esac
  done
else
  scenarios=("${@:-${ALL_SCENARIOS[@]}}")
fi

# Leaves nothing broken behind when a scenario fails halfway.
cleanup() {
  if [ -n "$E2E_CONTEXT" ]; then
    # Everything the scenarios created lives in their namespaces, volumes included.
    if [ -z "${KEEP_CLUSTER:-}" ]; then
      kubectl delete namespace "$NAMESPACE" "$NAMESPACE-seed" --ignore-not-found --wait=false \
        >/dev/null 2>&1 || true
    fi
    rm -f "$KUBECONFIG"
    return 0
  fi
  heal_partition
  restore_cluster_dns
  if [ -z "${KEEP_CLUSTER:-}" ]; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    docker network rm "$NODE_NETWORK" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "preparing the cluster"
ensure_cluster
load_images

suite_started=$SECONDS
for scenario in "${scenarios[@]}"; do
  log "$scenario"
  scenario_started=$SECONDS
  "scenario_$scenario"
  printf '    %s took %ss\n' "$scenario" $((SECONDS - scenario_started))
done

log "all ${#scenarios[@]} scenarios passed in $((SECONDS - suite_started))s"
