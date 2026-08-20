{{/*
Chart name.
*/}}
{{- define "monitoring-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to the objects this umbrella chart owns directly
(the dashboard ConfigMaps). Subchart objects get their own labels.
*/}}
{{- define "monitoring-stack.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "monitoring-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: monitoring-stack
{{- end -}}

{{/*
Guard against the single most damaging misconfiguration of this chart.

Helm values files cannot be templated, so the cross-component URLs in
values.yaml — Prometheus' remote_write target, the three Grafana datasource
URLs, and Alloy's loki.write endpoint — are written out literally as
"monitoring-*" service names.

Installing under a different release name renames those Services but not the
URLs pointing at them. Nothing errors: Prometheus comes up, Loki comes up,
Grafana comes up, and every single dashboard is silently empty. That is a
miserable thing to debug, so we refuse to render instead.

`helm lint` cannot set a release name (it hardcodes "test-release" and has no
--name-template flag), so linting passes --set skipReleaseNameCheck=true. That
is the only intended use of the escape hatch.
*/}}
{{- define "monitoring-stack.validateReleaseName" -}}
{{- if and (ne .Release.Name "monitoring") (not .Values.skipReleaseNameCheck) -}}
{{- $msg := printf `
monitoring-stack expects the release name "monitoring" (got %q).

The cross-component URLs in values.yaml are hardcoded to "monitoring-*" Service
names, because Helm cannot template a values file. Installing under another name
would start every pod successfully and leave every dashboard empty.

Either install with the expected name:

    helm install monitoring ./monitoring-stack -n monitoring --create-namespace

or, to use %q, override each of these to match:

    prometheus.server.remoteWrite[0].url
    grafana.datasources."datasources.yaml".datasources[*].url   (3 of them)
    alloy.alloy.configMap.content                               (loki.write endpoint)
` .Release.Name .Release.Name -}}
{{- fail $msg -}}
{{- end -}}
{{- end -}}
