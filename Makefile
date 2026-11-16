CHART := helm/kvrocks
SCRIPTS := $(CHART)/files/scripts/*.sh tests/e2e/*.sh tests/prometheus/run.sh
LOADGEN := tests/e2e/loadgen

# Every optional resource switched on, so that the schemas of all of them are checked.
ALL_FEATURES := --set metrics.serviceMonitor.enabled=true --set metrics.prometheusRule.enabled=true \
	--set networkPolicy.enabled=true
RENDER := helm template kv $(CHART) --set auth.password=lint
# The second location resolves the Prometheus Operator CRDs.
KUBECONFORM := kubeconform -strict -summary -schema-location default -schema-location \
	'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# The scenarios worth running on every change. Node failures, the network partition and
# volume losses only run in the full suite.
QUICK_SCENARIOS := install switchover rolling_update master_pod_crash helm_test

.PHONY: test lint schema manifests unit rules loadgen e2e e2e-quick

test: lint manifests unit rules loadgen ## Everything except the end-to-end scenarios

lint: schema ## Shell scripts, chart, and a values schema in sync with values.yaml
	shellcheck $(SCRIPTS)
	helm lint $(CHART) --set auth.password=lint
	git diff --exit-code -- $(CHART)/values.schema.json

schema: ## Regenerates values.schema.json from the annotations in values.yaml
	cd $(CHART) && helm schema -input values.yaml -output values.schema.json \
		-noAdditionalProperties true -indent 2

manifests: ## Rendered manifests against the Kubernetes and Prometheus Operator schemas
	$(RENDER) $(ALL_FEATURES) | $(KUBECONFORM)
	$(RENDER) --set architecture=standalone | $(KUBECONFORM)

unit: ## helm-unittest suites
	helm unittest $(CHART)

rules: ## Unit tests of the alert rules
	tests/prometheus/run.sh

loadgen: ## Lint, types and tests of the load generator used by the end-to-end scenarios
	cd $(LOADGEN) && uv sync --dev --frozen
	cd $(LOADGEN) && uv run ruff format --check . && uv run ruff check .
	cd $(LOADGEN) && uv run mypy loadgen.py test_loadgen.py && uv run pytest -q

e2e: ## Every failure scenario on a local Kind cluster (needs docker, kind, kubectl, jq)
	tests/e2e/run.sh

e2e-quick: ## The handover, rolling update and master crash scenarios only
	tests/e2e/run.sh $(QUICK_SCENARIOS)
