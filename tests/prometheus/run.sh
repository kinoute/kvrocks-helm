#!/usr/bin/env bash
# Renders the chart's alert rules and runs their unit tests.
# Needs helm, yq and promtool.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p .rendered

# The tests expect release "kv" in namespace "kv".
helm template kv ../../helm/kvrocks --namespace kv --set auth.password=unused \
  --set metrics.prometheusRule.enabled=true --show-only templates/prometheusrule.yaml |
  yq '.spec' >.rendered/rules.yaml

promtool check rules .rendered/rules.yaml
promtool test rules rules_test.yaml
