#!/usr/bin/env bash
# A new chart version alone must leave the pod templates as they are: any change to them
# restarts every pod, and the Kvrocks pods one handover at a time.
#
# Usage: tests/chart/pod-templates.sh    needs helm.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp -R helm/kvrocks "$work/next"
sed -i.orig -e 's/^version: .*/version: 99.0.0/' -e 's/^appVersion: .*/appVersion: "99.0.0"/' \
  "$work/next/Chart.yaml"

# The pod templates of the StatefulSet and of the HAProxy Deployment. The Kvrocks image is
# pinned: by default a new appVersion is a new image, which must restart the pods.
pod_templates() { # $1: chart directory
  helm template db "$1" --set auth.password=unused --set image.tag=2.17.0 \
    --show-only templates/statefulset.yaml --show-only templates/haproxy/deployment.yaml |
    awk '/^  template:/ { inside = 1 } /^  volumeClaimTemplates:/ || /^---/ { inside = 0 } inside'
}

if ! diff -u <(pod_templates helm/kvrocks) <(pod_templates "$work/next"); then
  echo "a new chart version changes the pod templates above: it would restart every pod" >&2
  exit 1
fi
echo "a new chart version leaves the pod templates as they are"
