{{- define "kvrocks.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* 47 characters at most: the longest suffix, "-haproxy-metrics", must fit in 63. */}}
{{- define "kvrocks.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 47 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 47 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 47 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "kvrocks.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "kvrocks.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Selector labels of one component. Usage: include "kvrocks.selectorLabels" (dict "root" . "component" "kvrocks") */}}
{{- define "kvrocks.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kvrocks.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/* Image reference. Usage: include "kvrocks.image" (dict "root" . "image" .Values.image "defaultTag" .Chart.AppVersion) */}}
{{- define "kvrocks.image" -}}
{{- $registry := default .image.registry .root.Values.global.imageRegistry }}
{{- if .image.digest }}
{{- printf "%s/%s@%s" $registry .image.repository .image.digest }}
{{- else }}
{{- printf "%s/%s:%s" $registry .image.repository (default .defaultTag .image.tag) }}
{{- end }}
{{- end }}

{{- define "kvrocks.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "kvrocks.isReplication" -}}
{{- if eq .Values.architecture "replication" }}true{{- end }}
{{- end }}

{{- define "kvrocks.haproxyEnabled" -}}
{{- if and (include "kvrocks.isReplication" .) .Values.haproxy.enabled }}true{{- end }}
{{- end }}

{{- define "kvrocks.replicaCount" -}}
{{- if include "kvrocks.isReplication" . }}{{ .Values.replicaCount }}{{ else }}1{{ end }}
{{- end }}

{{/* Sentinels that must agree: a majority of the pods unless set explicitly. */}}
{{- define "kvrocks.quorum" -}}
{{- if .Values.sentinel.quorum }}
{{- .Values.sentinel.quorum }}
{{- else }}
{{- add (div (int .Values.replicaCount) 2) 1 }}
{{- end }}
{{- end }}

{{/*
Sentinels that must name the same pod before HAProxy sends it writes. Always a strict
majority, whatever sentinel.quorum says: only one pod at a time can have a majority.
*/}}
{{- define "kvrocks.majority" -}}
{{- add (div (int .Values.replicaCount) 2) 1 }}
{{- end }}

{{/*
The scripts ConfigMap carries a hash of its content in its name. A mounted ConfigMap is
updated in place, so during an upgrade a pod that has not restarted yet would otherwise
run the new scripts with its old environment.
*/}}
{{- define "kvrocks.scriptsConfigMapName" -}}
{{- $hash := include "kvrocks.scriptsData" . | sha256sum | trunc 7 }}
{{- printf "%s-scripts-%s" (include "kvrocks.fullname" .) $hash }}
{{- end }}

{{- define "kvrocks.scriptsData" -}}
{{- range $path, $_ := .Files.Glob "files/scripts/*.sh" }}
{{ base $path }}: |
  {{- $.Files.Get $path | nindent 2 }}
{{- end }}
{{- end }}

{{/* The port in clear for the traffic inside the release: the client port without TLS. */}}
{{- define "kvrocks.internalPort" -}}
{{- if .Values.tls.enabled }}{{ .Values.tls.internalPort }}{{ else }}{{ .Values.port }}{{ end }}
{{- end }}

{{- define "kvrocks.headlessServiceName" -}}
{{- printf "%s-headless" (include "kvrocks.fullname" .) }}
{{- end }}

{{/* DNS suffix shared by every Kvrocks pod: <pod>.<this domain> */}}
{{- define "kvrocks.peersDomain" -}}
{{- printf "%s.%s.svc.%s" (include "kvrocks.headlessServiceName" .) .Release.Namespace .Values.clusterDomain }}
{{- end }}

{{/* Fully qualified name of one pod. Usage: include "kvrocks.podFqdn" (dict "root" . "ordinal" 0) */}}
{{- define "kvrocks.podFqdn" -}}
{{- printf "%s-%d.%s" (include "kvrocks.fullname" .root) (int .ordinal) (include "kvrocks.peersDomain" .root) }}
{{- end }}

{{- define "kvrocks.secretName" -}}
{{- default (include "kvrocks.fullname" .) .Values.auth.existingSecret }}
{{- end }}

{{- define "kvrocks.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kvrocks.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* The password as an environment variable, shared by every container that needs it. */}}
{{- define "kvrocks.passwordEnv" -}}
{{- if .Values.auth.enabled }}
- name: KVROCKS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "kvrocks.secretName" . }}
      key: {{ .Values.auth.secretKey }}
{{- end }}
{{- end }}

{{/*
A value as kvrocks.conf expects it. Helm reads YAML numbers as floats and would print a
large integer as 2.68e+08; an unquoted YAML yes/no arrives as a boolean.
*/}}
{{- define "kvrocks.configValue" -}}
{{- if kindIs "bool" . }}
{{- ternary "yes" "no" . }}
{{- else if and (kindIs "float64" .) (eq (floor .) .) }}
{{- int64 . }}
{{- else }}
{{- . }}
{{- end }}
{{- end }}

{{/*
Settings the chart writes itself; letting `config` override them would break the topology.
And rename-command, which would hide from the chart's scripts the commands they rely on: with
CLIENT renamed, the fencing could no longer pause the writes of an isolated master. And the
two settings of a replica the failover relies on, which `config` would set on every pod at
once: replicas that take writes drift from their master, and with a priority of 0 Sentinel
can promote none of them, so none is ever ready.
*/}}
{{- define "kvrocks.reservedConfigKeys" -}}
bind port dir pidfile log-dir daemonize cluster-enabled requirepass masterauth slaveof replicaof replica-announce-ip replica-announce-port tls-port tls-cert-file tls-key-file tls-ca-cert-file tls-auth-clients tls-protocols tls-replication rename-command slave-read-only slave-priority
{{- end }}

{{/* Fails the render on values that would produce a broken or unsafe deployment. */}}
{{- define "kvrocks.validate" -}}
{{- if and .Values.auth.enabled (not .Values.auth.existingSecret) (not .Values.auth.password) }}
{{- fail "auth is enabled: set auth.existingSecret or auth.password" }}
{{- end }}
{{- if regexMatch "[\\s\"'\\\\]" (toString .Values.auth.password) }}
{{- fail "auth.password must not contain whitespace, quotes or backslashes: HAProxy sends it in its health checks" }}
{{- end }}
{{- if .Values.tls.enabled }}
{{- if not .Values.tls.existingSecret }}
{{- fail "tls.enabled needs tls.existingSecret, the Secret with the server certificate" }}
{{- end }}
{{- if and .Values.tls.authClients (not .Values.tls.ca.secret) }}
{{- fail "tls.authClients needs tls.ca.secret, the CA client certificates must chain to" }}
{{- end }}
{{- if and .Values.tls.clientSecret (not .Values.tls.ca.secret) }}
{{- fail "tls.clientSecret needs tls.ca.secret: helm test checks the server certificate against that CA" }}
{{- end }}
{{- if eq (int .Values.tls.internalPort) (int .Values.port) }}
{{- fail "tls.internalPort must differ from port: Kvrocks serves TLS on port and keeps internalPort in clear" }}
{{- end }}
{{- /*
Without HAProxy, clients ask Sentinel for the master. Under TLS, Sentinel speaks in clear,
stays closed to clients, and would give them the port in clear anyway.
*/}}
{{- if and (include "kvrocks.isReplication" .) (not .Values.haproxy.enabled) }}
{{- fail "tls.enabled needs haproxy.enabled in replication: Sentinel stays inside the release, and clients would have no way to the master" }}
{{- end }}
{{- end }}
{{- /* The containers of a pod share its network: two of them cannot listen on one port. */}}
{{- $kvrocksPorts := list (int .Values.port) }}
{{- if .Values.tls.enabled }}
{{- $kvrocksPorts = append $kvrocksPorts (int .Values.tls.internalPort) }}
{{- end }}
{{- if include "kvrocks.isReplication" . }}
{{- $kvrocksPorts = append $kvrocksPorts (int .Values.sentinel.port) }}
{{- end }}
{{- if .Values.metrics.enabled }}
{{- $kvrocksPorts = append $kvrocksPorts (int .Values.metrics.port) }}
{{- end }}
{{- $portsSeen := dict }}
{{- range $port := $kvrocksPorts }}
{{- if hasKey $portsSeen (toString $port) }}
{{- fail (printf "port %d is used twice in the Kvrocks pods: port, tls.internalPort, sentinel.port and metrics.port must differ" $port) }}
{{- end }}
{{- $_ := set $portsSeen (toString $port) true }}
{{- end }}
{{- if and (include "kvrocks.haproxyEnabled" .) (eq (int .Values.port) (int .Values.haproxy.healthPort)) }}
{{- fail "haproxy.healthPort must differ from port: HAProxy listens on both" }}
{{- end }}
{{- /*
Kvrocks reads a key in any case, and a value with a line break adds a line of its own: either
would slip a reserved setting past the check below. The namespace tokens are credentials, and
`config` is stored in a ConfigMap, in clear.
*/}}
{{- range $key, $value := .Values.config }}
{{- if hasPrefix "namespace." (lower $key) }}
{{- fail (printf "config.%s: namespace tokens are credentials, and config is stored in a ConfigMap" $key) }}
{{- end }}
{{- if not (regexMatch "^[a-z0-9._-]+$" $key) }}
{{- fail (printf "config.%s: a key is lowercase letters, digits, dots, dashes and underscores, as kvrocks.conf spells it" $key) }}
{{- end }}
{{- if regexMatch "[\\r\\n]" (toString $value) }}
{{- fail (printf "config.%s must fit on one line: a line break would start a setting of its own" $key) }}
{{- end }}
{{- end }}
{{- range $key := splitList " " (include "kvrocks.reservedConfigKeys" .) }}
{{- if hasKey $.Values.config $key }}
{{- fail (printf "config.%s is managed by the chart and cannot be overridden" $key) }}
{{- end }}
{{- end }}
{{- if include "kvrocks.isReplication" . }}
{{- if lt (int .Values.replicaCount) 3 }}
{{- fail "replication needs replicaCount >= 3: with fewer pods, losing one leaves no Sentinel majority" }}
{{- end }}
{{- $quorum := int (include "kvrocks.quorum" .) }}
{{- if or (lt $quorum 1) (gt $quorum (int .Values.replicaCount)) }}
{{- fail "sentinel.quorum must be between 1 and replicaCount: no more Sentinels than pods can agree" }}
{{- end }}
{{- /* A drain that stops more pods than this leaves no Sentinel majority, so no failover. */}}
{{- $maxUnavailable := sub (int .Values.replicaCount) (int (include "kvrocks.majority" .)) }}
{{- if and .Values.podDisruptionBudget.enabled (gt (int .Values.podDisruptionBudget.maxUnavailable) $maxUnavailable) }}
{{- fail (printf "podDisruptionBudget.maxUnavailable must be at most %d with %d pods: a drain must leave a majority of Sentinels" $maxUnavailable (int .Values.replicaCount)) }}
{{- end }}
{{- if not .Values.image.digest }}
{{- $version := trimPrefix "v" (default .Chart.AppVersion .Values.image.tag) }}
{{- if and (regexMatch "^[0-9]+\\.[0-9]+\\.[0-9]+" $version) (not (semverCompare ">=2.16.0-0" $version)) }}
{{- fail (printf "image.tag %s: replication needs Kvrocks 2.16.0 or later, the first with CLIENT PAUSE WRITE" $version) }}
{{- end }}
{{- end }}
{{- if ge (int .Values.switchover.pauseMilliseconds) (int .Values.sentinel.downAfterMilliseconds) }}
{{- fail "switchover.pauseMilliseconds must be lower than sentinel.downAfterMilliseconds, or Sentinel declares the paused master down" }}
{{- end }}
{{- /*
The preStop hook of a master runs the handover: the write pause, then at worst the whole
failover timeout of Sentinel. Kvrocks then stops and flushes its WAL. Killed before, the pod
leaves the failover to finish without it, writes paused.
*/}}
{{- $stopSeconds := 30 }}
{{- $handoverSeconds := div (add (int64 .Values.switchover.pauseMilliseconds) (int64 .Values.sentinel.failoverTimeoutMilliseconds) 999) 1000 }}
{{- $minGraceSeconds := add $handoverSeconds $stopSeconds }}
{{- if lt (int64 .Values.terminationGracePeriodSeconds) $minGraceSeconds }}
{{- fail (printf "terminationGracePeriodSeconds must be at least %d: the handover of a master can take switchover.pauseMilliseconds plus sentinel.failoverTimeoutMilliseconds, then Kvrocks needs %d s to stop" $minGraceSeconds $stopSeconds) }}
{{- end }}
{{- end }}
{{- end }}

{{- /* Settings both the kvrocks and the sentinel scripts read. */}}
{{- define "kvrocks.topologyEnv" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: KVROCKS_ARCHITECTURE
  value: {{ .Values.architecture | quote }}
- name: KVROCKS_STATEFULSET
  value: {{ include "kvrocks.fullname" . | quote }}
- name: KVROCKS_PEERS_DOMAIN
  value: {{ include "kvrocks.peersDomain" . | quote }}
- name: KVROCKS_REPLICAS
  value: {{ include "kvrocks.replicaCount" . | quote }}
- name: KVROCKS_PORT
  value: {{ include "kvrocks.internalPort" . | quote }}
- name: SENTINEL_PORT
  value: {{ .Values.sentinel.port | quote }}
- name: SENTINEL_MASTER_NAME
  value: {{ .Values.sentinel.masterName | quote }}
- name: SENTINEL_MAJORITY
  value: {{ include "kvrocks.majority" . | quote }}
- name: SWITCHOVER_PAUSE_MS
  value: {{ .Values.switchover.pauseMilliseconds | int64 | quote }}
- name: SENTINEL_FAILOVER_TIMEOUT_MS
  value: {{ .Values.sentinel.failoverTimeoutMilliseconds | int64 | quote }}
{{- include "kvrocks.passwordEnv" . }}
{{- end }}
