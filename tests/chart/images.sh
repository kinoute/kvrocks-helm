#!/usr/bin/env bash
# The artifacthub.io/images annotation of Chart.yaml is written by hand: it must list the images
# the chart deploys, no more, no less.
#
# Usage: tests/chart/images.sh    needs helm and yq.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

rendered=$(helm template db helm/kvrocks --set auth.password=unused |
  yq -N '.. | select(tag == "!!map" and has("image")) | .image' | sort -u)
listed=$(yq '.annotations."artifacthub.io/images"' helm/kvrocks/Chart.yaml | yq '.[].image' | sort -u)

if ! diff -u <(printf '%s\n' "$listed") <(printf '%s\n' "$rendered"); then
  echo "artifacthub.io/images in Chart.yaml (-) does not list the images the chart deploys (+)" >&2
  exit 1
fi
echo "artifacthub.io/images lists the images the chart deploys"
