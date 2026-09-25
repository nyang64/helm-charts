{{/*
Expand the name of the chart.
*/}}
{{- define "aimlp-search.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "aimlp-search.fullname" -}}
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
{{- define "aimlp-search.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "aimlp-search.labels" -}}
helm.sh/chart: {{ include "aimlp-search.chart" . }}
{{ include "aimlp-search.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "aimlp-search.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aimlp-search.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "aimlp-search.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "aimlp-search.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Render podAntiAffinity block for a given role and antiAffinity setting.
Usage: include "aimlp-search.antiAffinity" (list . "master" .Values.master.antiAffinity)
*/}}
{{- define "aimlp-search.antiAffinity" -}}
{{- $root := index . 0 -}}
{{- $role := index . 1 -}}
{{- $mode := index . 2 -}}
{{- if eq $mode "required" }}
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            {{- include "aimlp-search.selectorLabels" $root | nindent 12 }}
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
              {{- include "aimlp-search.selectorLabels" $root | nindent 14 }}
              role: {{ $role }}
          topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{/*
HTTP scheme for ES port 9200.
When Istio is enabled, Envoy handles TLS on 9200 -- ES listens plain HTTP internally.
When Istio is disabled, scheme follows tls.enabled.
*/}}
{{- define "aimlp-search.httpScheme" -}}
{{- if or .Values.istio.enabled (not .Values.tls.enabled) -}}http{{- else -}}https{{- end -}}
{{- end }}

{{/* TLS secret name -- defaults to <fullname>-tls so two releases in the same namespace don't collide */}}
{{- define "aimlp-search.tlsSecretName" -}}
{{- .Values.tls.secretName | default (printf "%s-tls" (include "aimlp-search.fullname" .)) -}}
{{- end }}

{{/* TLS issuer name -- defaults to <fullname>-issuer */}}
{{- define "aimlp-search.tlsIssuerName" -}}
{{- .Values.tls.issuerName | default (printf "%s-issuer" (include "aimlp-search.fullname" .)) -}}
{{- end }}

{{/*
Generate comma-separated list of master pod names for cluster.initial_master_nodes
*/}}
{{- define "aimlp-search.masterNodes" -}}
{{- $fullname := include "aimlp-search.fullname" . -}}
{{- $replicas := .Values.master.replicas | int -}}
{{- range $i, $e := until $replicas -}}
  {{- if $i }},{{ end -}}
  {{- $fullname }}-master-{{ $i -}}
{{- end -}}
{{- end }}

{{/*
S3 keystore init container.
Loads S3 credentials AND bootstrap.password into the ES keystore on every pod start.
bootstrap.password must be pre-populated so the ES entrypoint does not attempt to write it
to the subPath-mounted keystore file at runtime -- that write uses an atomic rename which
bypasses the bind-mount inode, causing ES to start with a keystore missing the S3 keys.
Enabled only when snapshot.repository.s3.credentialsSecret is set.
*/}}
{{- define "aimlp-search.keystoreInitContainer" -}}
{{- if and .Values.snapshot.enabled (eq .Values.snapshot.repository.type "s3") .Values.snapshot.repository.s3.credentialsSecret -}}
- name: keystore-init
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    runAsUser: 1000
    capabilities:
      drop:
        - ALL
  command:
    - /bin/sh
    - -c
    - |
      elasticsearch-keystore create
      printf '%s' "${S3_ACCESS_KEY}" | elasticsearch-keystore add --stdin s3.client.default.access_key
      printf '%s' "${S3_SECRET_KEY}" | elasticsearch-keystore add --stdin s3.client.default.secret_key
      {{- if .Values.security.enabled }}
      printf '%s' "${ELASTIC_PASSWORD}" | elasticsearch-keystore add --stdin bootstrap.password
      {{- end }}
      cp /usr/share/elasticsearch/config/elasticsearch.keystore /keystore-vol/
  env:
    - name: S3_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: {{ .Values.snapshot.repository.s3.credentialsSecret }}
          key: access_key
    - name: S3_SECRET_KEY
      valueFrom:
        secretKeyRef:
          name: {{ .Values.snapshot.repository.s3.credentialsSecret }}
          key: secret_key
    {{- if .Values.security.enabled }}
    - name: ELASTIC_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ .Values.elasticPassword.existingSecret | default (printf "%s-bootstrap" (include "aimlp-search.fullname" .)) }}
          key: ELASTIC_PASSWORD
    {{- end }}
  volumeMounts:
    - name: keystore
      mountPath: /keystore-vol
{{- end -}}
{{- end }}

{{/*
Keystore volumeMount for the main ES container.
Mounts the keystore file written by keystoreInitContainer via a shared emptyDir.
Not readOnly: the ES entrypoint writes bootstrap.password via atomic rename; that rename
creates a new inode at the config path, leaving the bind-mount pointing at our pre-built
inode. The pre-built keystore already contains bootstrap.password so ES starts correctly.
*/}}
{{- define "aimlp-search.keystoreVolumeMount" -}}
{{- if and .Values.snapshot.enabled (eq .Values.snapshot.repository.type "s3") .Values.snapshot.repository.s3.credentialsSecret -}}
- name: keystore
  mountPath: /usr/share/elasticsearch/config/elasticsearch.keystore
  subPath: elasticsearch.keystore
{{- end -}}
{{- end }}

{{/*
Keystore emptyDir volume -- shared between keystoreInitContainer and the main ES container.
*/}}
{{- define "aimlp-search.keystoreVolume" -}}
{{- if and .Values.snapshot.enabled (eq .Values.snapshot.repository.type "s3") .Values.snapshot.repository.s3.credentialsSecret -}}
- name: keystore
  emptyDir: {}
{{- end -}}
{{- end }}
