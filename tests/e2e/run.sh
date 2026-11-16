#!/usr/bin/env bash
# End-to-end tests of the chart on a local Kind cluster.
#
# Usage: tests/e2e/run.sh [scenario ...]    every scenario, in order, by default
#        KEEP_CLUSTER=1 tests/e2e/run.sh    keeps the cluster afterwards, to look around
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
  plain_sentinel_failover
  rolling_update
  drain
  haproxy_restart
  master_pod_crash
  master_node_failure
  master_partition
  master_isolated_from_peers
  replica_volume_loss
  master_volume_loss
  full_outage
  stale_master_starts_first
  empty_first_pod_after_outage
  network_policy
  standalone
  helm_test
)

ensure_cluster() {
  mkdir -p "$(dirname "$KUBECONFIG")"
  if kind get clusters 2>/dev/null | grep -q -x "$CLUSTER_NAME"; then
    kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
  else
    kind create cluster --name "$CLUSTER_NAME" --config "$E2E_DIR/kind.yaml" --kubeconfig "$KUBECONFIG"
  fi
  kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
}

# Only the load generator is built here. The chart's own images are pulled by the nodes,
# as on a real cluster.
load_images() {
  # Without provenance: its attestation manifest makes `kind load` fail on a missing digest.
  docker build --quiet --provenance=false --tag "$LOADGEN_IMAGE" "$E2E_DIR/loadgen" >/dev/null
  kind load docker-image "$LOADGEN_IMAGE" --name "$CLUSTER_NAME" >/dev/null 2>&1 ||
    fail "could not load $LOADGEN_IMAGE into the cluster"
}

# Leaves nothing broken behind when a scenario fails halfway.
cleanup() {
  heal_partition
  if [ -z "${KEEP_CLUSTER:-}" ]; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

scenarios=("${@:-${ALL_SCENARIOS[@]}}")

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
