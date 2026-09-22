{{/*
Expand the name of the chart.
*/}}
{{- define "es-poc-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "es-poc-cluster.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "es-poc-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "es-poc-cluster.labels" -}}
helm.sh/chart: {{ include "es-poc-cluster.chart" . }}
{{ include "es-poc-cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "es-poc-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "es-poc-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "es-poc-cluster.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "es-poc-cluster.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render podAntiAffinity block for a given role and antiAffinity setting.
Usage: include "es-poc-cluster.antiAffinity" (list . "master" .Values.master.antiAffinity)
*/}}
{{- define "es-poc-cluster.antiAffinity" -}}
{{- $root := index . 0 -}}
{{- $role := index . 1 -}}
{{- $mode := index . 2 -}}
{{- if eq $mode "required" }}
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            {{- include "es-poc-cluster.selectorLabels" $root | nindent 12 }}
            role: {{ $role }}
        topologyKey: kubernetes.io/hostname
{{- else if eq $mode "preferred" }}
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              {{- include "es-poc-cluster.selectorLabels" $root | nindent 14 }}
              role: {{ $role }}
          topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{/*
HTTP scheme for ES port 9200.
When Istio is enabled, Envoy handles TLS on 9200 -- ES listens plain HTTP internally.
When Istio is disabled, scheme follows tls.enabled.
*/}}
{{- define "es-poc-cluster.httpScheme" -}}
{{- if or .Values.istio.enabled (not .Values.tls.enabled) -}}http{{- else -}}https{{- end -}}
{{- end }}

{{/* TLS secret name -- defaults to <fullname>-tls so two releases in the same namespace don't collide */}}
{{- define "es-poc-cluster.tlsSecretName" -}}
{{- .Values.tls.secretName | default (printf "%s-tls" (include "es-poc-cluster.fullname" .)) -}}
{{- end }}

{{/* TLS issuer name -- defaults to <fullname>-issuer */}}
{{- define "es-poc-cluster.tlsIssuerName" -}}
{{- .Values.tls.issuerName | default (printf "%s-issuer" (include "es-poc-cluster.fullname" .)) -}}
{{- end }}

{{/*
Generate comma-separated list of master pod names for cluster.initial_master_nodes
*/}}
{{- define "es-poc-cluster.masterNodes" -}}
{{- $fullname := include "es-poc-cluster.fullname" . -}}
{{- $replicas := .Values.master.replicas | int -}}
{{- range $i, $e := until $replicas -}}
  {{- if $i }},{{ end -}}
  {{- $fullname }}-master-{{ $i -}}
{{- end -}}
{{- end }}
