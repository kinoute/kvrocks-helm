#!/usr/bin/env bash
# Unit tests of the chart's scripts against a fake redis-cli, each in the image it runs in:
# the kvrocks image (dash) or the Sentinel image (busybox ash).
#
# Usage: tests/scripts/run.sh [test file ...]    every test_*.sh by default. Needs docker and helm.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
repo=$(cd ../.. && pwd)

# The images the chart deploys, read from the rendered chart.
images=$(helm template t "$repo/helm/kvrocks" --set auth.password=unused | awk '$1 == "image:" { print $2 }' | sort -u)
kvrocks_image=$(grep '/apache/kvrocks:' <<<"$images" | head -n 1)
sentinel_image=$(grep '/valkey/valkey:' <<<"$images" | head -n 1)

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  files=(test_*.sh)
fi

failed=0
for file in "${files[@]}"; do
  case "$(sed -n 's/^# image: //p' "$file")" in
    kvrocks) image=$kvrocks_image ;;
    sentinel) image=$sentinel_image ;;
    *) echo "$file: no '# image:' line" >&2; exit 2 ;;
  esac
  echo "$file ($image)"
  docker run --rm --user 0 --entrypoint sh \
    -v "$repo/helm/kvrocks/files/scripts:/scripts:ro" -v "$PWD:/tests:ro" \
    "$image" /tests/harness.sh "/tests/$(basename "$file")" || failed=1
done
exit "$failed"
