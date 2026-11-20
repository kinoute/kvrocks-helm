# pipefail: kubeconform passes on an empty input, so a render that fails must fail the
# pipeline itself. In SHELL: the make 3.81 of macOS ignores .SHELLFLAGS.
SHELL := bash -o pipefail

CHART := helm/kvrocks
SCRIPTS := $(CHART)/files/scripts/*.sh tests/e2e/*.sh tests/prometheus/run.sh \
	tests/scripts/run.sh tests/scripts/harness.sh tests/scripts/fake/* tests/chart/*.sh
LOADGEN := tests/e2e/loadgen

# Every optional resource switched on, so that the schemas of all of them are checked.
ALL_FEATURES := --set metrics.serviceMonitor.enabled=true --set metrics.prometheusRule.enabled=true \
	--set networkPolicy.enabled=true
TLS := --set tls.enabled=true --set tls.existingSecret=kv-tls --set tls.ca.secret=kv-ca \
	--set tls.clientSecret=kv-client-tls --set tls.reloader=true
# Every value that extends the pods and the Services, so that their schemas are checked too.
EXTENSIONS := --set commonAnnotations.team=data --set persistence.retentionPolicy.whenDeleted=Delete \
	--set-json 'nodeAffinity={"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"pool","operator":"In","values":["databases"]}]}]}}' \
	--set service.type=LoadBalancer --set 'service.loadBalancerSourceRanges={10.0.0.0/8}' \
	--set readService.type=NodePort --set readService.nodePort=30380 \
	--set-json 'extraEnv=[{"name":"TZ","value":"UTC"}]' \
	--set-json 'extraVolumes=[{"name":"backup","emptyDir":{}}]' \
	--set-json 'extraVolumeMounts=[{"name":"backup","mountPath":"/backup"}]' \
	--set-json 'sidecars=[{"name":"backup-agent","image":"busybox:1.37","volumeMounts":[{"name":"data","mountPath":"/data","readOnly":true}]}]'
RENDER := helm template kv $(CHART) --set auth.password=lint
# The oldest Kubernetes the chart accepts, read from the kubeVersion of Chart.yaml (">=1.34.0-0").
OLDEST_KUBERNETES := $(shell sed -n 's/^kubeVersion: ">=\([0-9.]*\)-0"$$/\1/p' $(CHART)/Chart.yaml)
# The second location resolves the Prometheus Operator CRDs.
KUBECONFORM := kubeconform -strict -summary -schema-location default -schema-location \
	'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# The scenarios worth running on every change, the fencing of an isolated master and the
# guard against an empty volume included: a change that breaks either must not wait for
# the full suite on main to show. Node failures, the full outages and DNS only run there.
QUICK_SCENARIOS := install switchover rolling_update master_pod_crash master_isolated_from_peers \
	master_volume_loss tls_clients helm_test

.PHONY: test lint schema docs manifests unit scripts rules loadgen e2e e2e-quick e2e-cluster

test: lint manifests unit scripts rules loadgen ## Everything except the end-to-end scenarios

lint: ## Shell scripts, chart, and a values schema and a chart README in sync with values.yaml
	shellcheck $(SCRIPTS)
	helm lint $(CHART) --set auth.password=lint
	mkdir -p .e2e
	cd $(CHART) && helm schema -input values.yaml -output $(CURDIR)/.e2e/values.schema.json \
		-noAdditionalProperties true -indent 2 >/dev/null
	diff -u $(CHART)/values.schema.json .e2e/values.schema.json || \
		{ echo "values.schema.json is out of date: run make schema"; exit 1; }
	helm-docs --chart-search-root $(dir $(CHART)) --dry-run 2>/dev/null >.e2e/README.md
	diff -u $(CHART)/README.md .e2e/README.md || \
		{ echo "$(CHART)/README.md is out of date: run make docs"; exit 1; }

schema: ## Regenerates values.schema.json from the annotations in values.yaml
	cd $(CHART) && helm schema -input values.yaml -output values.schema.json \
		-noAdditionalProperties true -indent 2

docs: ## Regenerates the chart's README.md from README.md.gotmpl and values.yaml
	helm-docs --chart-search-root $(dir $(CHART))

manifests: ## Rendered manifests against the Kubernetes and Prometheus Operator schemas, the oldest Kubernetes included
	$(RENDER) $(ALL_FEATURES) | $(KUBECONFORM)
	$(RENDER) --set architecture=standalone | $(KUBECONFORM)
	$(RENDER) $(ALL_FEATURES) $(TLS) $(EXTENSIONS) | $(KUBECONFORM)
	@test -n "$(OLDEST_KUBERNETES)" || { echo "cannot read kubeVersion from $(CHART)/Chart.yaml"; exit 1; }
	$(RENDER) $(ALL_FEATURES) $(TLS) $(EXTENSIONS) --kube-version $(OLDEST_KUBERNETES) | \
		$(KUBECONFORM) -kubernetes-version $(OLDEST_KUBERNETES)

unit: ## helm-unittest suites, pod templates that a new chart version leaves as they are, images listed for ArtifactHub
	helm unittest $(CHART)
	tests/chart/pod-templates.sh
	tests/chart/images.sh

scripts: ## Unit tests of the pod scripts against a fake redis-cli, in their own images (needs docker)
	tests/scripts/run.sh

rules: ## Unit tests of the alert rules
	tests/prometheus/run.sh

loadgen: ## Lint, types and tests of the load generator used by the end-to-end scenarios
	cd $(LOADGEN) && uv sync --dev --frozen
	cd $(LOADGEN) && uv run ruff format --check . && uv run ruff check .
	cd $(LOADGEN) && uv run mypy loadgen.py dataset.py test_loadgen.py test_dataset.py && uv run pytest -q

e2e: ## Every failure scenario on a local Kind cluster (needs docker, kind, kubectl, jq)
	tests/e2e/run.sh

e2e-quick: ## The handover, rolling update, master crash and TLS client scenarios only
	tests/e2e/run.sh $(QUICK_SCENARIOS)

e2e-cluster: ## The scenarios that leave nodes alone, on an existing cluster: CONTEXT=<kube context>
	@test -n "$(CONTEXT)" || { echo "usage: make e2e-cluster CONTEXT=<kube context>"; exit 1; }
	E2E_CONTEXT=$(CONTEXT) tests/e2e/run.sh
