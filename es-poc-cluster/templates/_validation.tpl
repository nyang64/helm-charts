{{/*
Validate that incompatible value combinations are caught at template render time,
not at Elasticsearch startup time inside the cluster.
*/}}

{{- if and .Values.security.enabled (not .Values.tls.enabled) }}
{{- fail "Invalid configuration: security.enabled=true requires tls.enabled=true. ES 8.x mandates transport TLS on all multi-node clusters when security is enabled. Either set tls.enabled=true (recommended) or set security.enabled=false (dev/test only)." }}
{{- end }}

{{- if and .Values.ad.enabled (not .Values.security.enabled) }}
{{- fail "Invalid configuration: ad.enabled=true requires security.enabled=true. Active Directory authentication cannot function without xpack security." }}
{{- end }}
