#!/usr/bin/env bash
# Pushes helm/artifacthub-repo.yml under the tag `artifacthub.io` of the chart's OCI repository,
# where ArtifactHub looks for it, unless the tag already holds that very file: every push would
# leave one more untagged version in the registry otherwise.
#
# Usage: .github/scripts/push-artifacthub-metadata.sh <repository> [oras options]
#        e.g. ghcr.io/kinoute/charts/kvrocks    needs oras and jq, and a login to the registry.
set -euo pipefail

repository=$1
shift

cd "$(dirname "${BASH_SOURCE[0]}")/../../helm"

wanted="sha256:$(sha256sum artifacthub-repo.yml | cut -d ' ' -f 1)"
pushed=$(oras manifest fetch "$@" "$repository:artifacthub.io" 2>/dev/null | jq -r '.layers[0].digest' || true)
if [ "$pushed" = "$wanted" ]; then
  echo "$repository:artifacthub.io already holds artifacthub-repo.yml"
  exit 0
fi

oras push "$@" "$repository:artifacthub.io" \
  --config /dev/null:application/vnd.cncf.artifacthub.config.v1+yaml \
  artifacthub-repo.yml:application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml
