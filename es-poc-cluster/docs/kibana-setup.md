# Kibana Setup Guide

Kibana is deployed as a **separate Helm chart** (`elastic/kibana`) that points at the
Elasticsearch cluster managed by this chart. This guide covers the thin overlay needed
to wire the two together, for both TLS (non-Istio) and Istio mesh deployments.

## Prerequisites

1. ES cluster is healthy (`kubectl get pods -n <es-namespace>` — all pods Running/Ready).
2. You have completed the **Kibana integration step** in the ES post-install runbook
   (`helm get notes <release> -n <es-namespace>`), which produces:
   - A `kibana-es-token` secret in the Kibana namespace (the service account token).
   - A `es-ca` secret in the Kibana namespace (the ES CA cert) — **TLS path only**.

## Add the Elastic Helm repository

```bash
helm repo add elastic https://helm.elastic.co
helm repo update
```

## Overlay variants

### Variant A — TLS enabled, no Istio

Use this when `tls.enabled=true` and `istio.enabled=false` in your ES chart values.
Kibana connects over HTTPS and must trust the cert-manager self-signed CA.

```yaml
# kibana-values-nonprod.yaml

# Pin to the same major.minor as your ES image tag.
image:
  tag: "8.17.7"

replicas: 1

# ES ingest service — use the fully-qualified in-cluster DNS name.
# Replace <es-release> and <es-namespace> with your actual values.
elasticsearchHosts: "https://<es-release>-ingest.<es-namespace>.svc:9200"

# Service account token -- never hardcode; always reference the K8s secret
# created in the post-install runbook.
extraEnvs:
  - name: ELASTICSEARCH_SERVICEACCOUNTTOKEN
    valueFrom:
      secretKeyRef:
        name: kibana-es-token   # created by the ES runbook step
        key: token

# Mount the ES CA certificate so Kibana can verify the ES TLS cert.
secretMounts:
  - name: es-ca
    secretName: es-ca           # created by the ES runbook step
    path: /usr/share/kibana/config/certs

kibanaConfig:
  kibana.yml: |
    # Trust the cert-manager self-signed CA used by the ES cluster.
    elasticsearch.ssl.certificateAuthorities: [/usr/share/kibana/config/certs/ca.crt]
    elasticsearch.ssl.verificationMode: certificate

    # Encryption keys are required for alerts, saved objects, and reporting.
    # Generate with: openssl rand -hex 32
    # Store in a vault -- do not commit plaintext keys to source control.
    xpack.security.encryptionKey: "<32-char-random-hex>"
    xpack.encryptedSavedObjects.encryptionKey: "<32-char-random-hex>"
    xpack.reporting.encryptionKey: "<32-char-random-hex>"

resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "1000m"
    memory: "1Gi"

service:
  type: ClusterIP   # expose via Ingress or port-forward; do not use LoadBalancer in shared clusters
```

### Variant B — Istio mesh (mTLS)

Use this when `istio.enabled=true` in your ES chart values. Kibana connects over plain
HTTP on port 9200 — Istio's Envoy sidecar handles mTLS between pods. No CA cert needed
on the Kibana side.

Before deploying, ensure Kibana's namespace is in `istio.allowedNamespaces` in your ES
chart values overlay so the Istio AuthorizationPolicy admits Kibana pods:

```yaml
# In your ES chart overlay (e.g. environments/nonprod.yaml):
istio:
  allowedNamespaces:
    - "kibana"   # or whatever namespace Kibana runs in
```

Then deploy Kibana with:

```yaml
# kibana-values-nonprod-istio.yaml

image:
  tag: "8.17.7"

replicas: 1

# Plain HTTP -- Istio handles mTLS between Kibana and ES pods.
elasticsearchHosts: "http://<es-release>-ingest.<es-namespace>.svc:9200"

extraEnvs:
  - name: ELASTICSEARCH_SERVICEACCOUNTTOKEN
    valueFrom:
      secretKeyRef:
        name: kibana-es-token
        key: token

# Inject the Istio sidecar into Kibana pods.
podAnnotations:
  sidecar.istio.io/inject: "true"

kibanaConfig:
  kibana.yml: |
    # No SSL config needed -- Istio handles transport security.
    xpack.security.encryptionKey: "<32-char-random-hex>"
    xpack.encryptedSavedObjects.encryptionKey: "<32-char-random-hex>"
    xpack.reporting.encryptionKey: "<32-char-random-hex>"

resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "1000m"
    memory: "1Gi"

service:
  type: ClusterIP
```

## Install

```bash
helm install kibana elastic/kibana \
  -f kibana-values-nonprod.yaml \
  -n kibana \
  --create-namespace \
  --version 8.17.7   # pin chart version to match ES
```

## Verify

```bash
# Check Kibana pod is Running
kubectl get pods -n kibana

# Port-forward and open in browser
kubectl port-forward svc/kibana-kibana 5601:5601 -n kibana
# Open https://localhost:5601 (or http:// for Istio path)
# Log in as elastic with the bootstrap password from the ES runbook
```

## Encryption key management

The three `xpack.*encryptionKey` values must:

- Be at least 32 characters of random data (`openssl rand -hex 32`).
- Stay **consistent across Kibana restarts and replicas** — changing them invalidates
  all saved alerts and encrypted saved objects. Store them in a secrets manager
  (Vault, AWS Secrets Manager, etc.) and inject via `extraEnvs` + `secretKeyRef`,
  not hardcoded in the values file.
- Be different from each other.

Recommended production pattern — store keys in a K8s secret and reference them:

```bash
kubectl create secret generic kibana-encryption-keys \
  --from-literal=security="$(openssl rand -hex 32)" \
  --from-literal=encryptedSavedObjects="$(openssl rand -hex 32)" \
  --from-literal=reporting="$(openssl rand -hex 32)" \
  -n kibana
```

```yaml
# In kibana-values.yaml, replace kibanaConfig keys with:
extraEnvs:
  - name: ELASTICSEARCH_SERVICEACCOUNTTOKEN
    valueFrom:
      secretKeyRef:
        name: kibana-es-token
        key: token
  - name: XPACK_SECURITY_ENCRYPTIONKEY
    valueFrom:
      secretKeyRef:
        name: kibana-encryption-keys
        key: security
  - name: XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY
    valueFrom:
      secretKeyRef:
        name: kibana-encryption-keys
        key: encryptedSavedObjects
  - name: XPACK_REPORTING_ENCRYPTIONKEY
    valueFrom:
      secretKeyRef:
        name: kibana-encryption-keys
        key: reporting
```

## Token rotation (zero downtime)

The ES service account supports multiple simultaneous tokens. To rotate without downtime:

```bash
# 1. Create a new token
curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST "$ES_URL/_security/service/elastic/kibana/credential/token/kibana-2?pretty"

# 2. Update the K8s secret with the new token value
kubectl create secret generic kibana-es-token \
  --from-literal=token="<new-value>" \
  -n kibana --dry-run=client -o yaml | kubectl apply -f -

# 3. Restart Kibana to pick up the new secret
kubectl rollout restart deployment/kibana-kibana -n kibana

# 4. After Kibana is healthy, delete the old token from ES
curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
  -X DELETE "$ES_URL/_security/service/elastic/kibana/credential/token/kibana-1"
```
