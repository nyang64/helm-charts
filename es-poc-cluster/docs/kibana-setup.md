# Kibana Setup Guide

Kibana is **deployed by this Helm chart** in the same namespace as Elasticsearch —
no separate Helm chart, no external dependency. This guide covers first-time setup,
encryption key management, and token rotation.

## Architecture

| Resource | Name | Notes |
|----------|------|-------|
| Deployment | `<release>-kibana` | RollingUpdate, maxUnavailable=0 |
| Service | `<release>-kibana` | ClusterIP on port 5601 |
| ConfigMap | `<release>-kibana-config` | kibana.yml (server + SSL config) |
| NetworkPolicy | `<release>-kibana` | egress → ES:9200 + DNS; ingress → 5601 |

**ES connection:**
- `istio.enabled=true` → `http://<release>-ingest.<namespace>.svc:9200` (Envoy handles mTLS)
- `istio.enabled=false` → `https://<release>-ingest.<namespace>.svc:9200` + CA cert mounted

**Authentication:** ES service account token scoped to `elastic/kibana`
(kibana_system privileges). Token is stored in ES as a SHA-256 hash; the plaintext
is shown once at creation and stored in a K8s Secret you own.

## Prerequisites

1. ES cluster is healthy — all pods Running/Ready (`kubectl get pods -n <namespace>`).
2. You have completed STEP 1 and STEP 2 of the post-install runbook
   (`helm get notes <release> -n <namespace>`).

## Step 1 — Create the ES service account token

With ES healthy and the `ES_URL` / `ELASTIC_PASSWORD` env vars set from the runbook:

```bash
curl -sf{{TLS_FLAG}} -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST "$ES_URL/_security/service/elastic/kibana/credential/token/kibana-1?pretty"
```

> **Save the `"value"` field from the response immediately.**  
> ES stores only the SHA-256 hash — the plaintext token is shown exactly once.
> If you lose it, create a new token (e.g. `kibana-2`) and delete the old one.

Verify the token authenticates correctly:

```bash
curl -sf{{TLS_FLAG}} -H "Authorization: Bearer <value-from-above>" \
  "$ES_URL/_security/_authenticate?pretty"
# Expected: "username": "elastic/kibana", "roles": []
# (service accounts authenticate via the service-account descriptor, not a role)
```

## Step 2 — Create the K8s token secret

```bash
kubectl create secret generic kibana-es-token \
  --from-literal=token="<value-from-step-1>" \
  -n <namespace>
```

## Step 3 — Create encryption key secrets (required for production)

Kibana requires three stable random keys for:
- **`security`** — encrypted session cookies; changing this logs out all users
- **`savedObjects`** — encrypted saved objects (alerting rules, connectors); changing this
  corrupts existing alerts and connectors
- **`reporting`** — encrypted reporting jobs

Without these keys, Kibana generates random values on every restart — sessions and saved
objects are lost whenever a pod restarts or a rolling update occurs.

```bash
kubectl create secret generic kibana-encryption-keys \
  --from-literal=security="$(openssl rand -hex 32)" \
  --from-literal=savedObjects="$(openssl rand -hex 32)" \
  --from-literal=reporting="$(openssl rand -hex 32)" \
  -n <namespace>
```

> **Store these in a secrets manager** (Vault, AWS Secrets Manager, etc.) before deleting
> the terminal history. If lost, existing encrypted saved objects cannot be recovered.

## Step 4 — Enable Kibana via helm upgrade

```bash
helm upgrade <release> . \
  -f environments/<your-env>.yaml \
  --set kibana.enabled=true \
  --set kibana.serviceAccountToken.existingSecret=kibana-es-token \
  --set kibana.encryptionKeys.existingSecret=kibana-encryption-keys \
  -n <namespace>
```

Or commit the values to your environment overlay and upgrade without `--set`:

```yaml
# environments/<your-env>.yaml
kibana:
  enabled: true
  serviceAccountToken:
    existingSecret: "kibana-es-token"
  encryptionKeys:
    existingSecret: "kibana-encryption-keys"
```

## Step 5 — Access Kibana

```bash
# Wait for the Deployment rollout
kubectl rollout status deployment/<release>-kibana -n <namespace>

# Port-forward for local access
kubectl port-forward svc/<release>-kibana 5601:5601 -n <namespace>
# Open: http://localhost:5601
# Log in as: elastic / <ELASTIC_PASSWORD>
```

For external access, configure an Istio VirtualService (when `istio.enabled=true`)
or a Kubernetes Ingress pointing at the `<release>-kibana` Service on port 5601.

## Token rotation (zero-downtime)

ES service accounts support multiple simultaneous tokens. To rotate without downtime:

```bash
# 1. Create a new token
curl -sf{{TLS_FLAG}} -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST "$ES_URL/_security/service/elastic/kibana/credential/token/kibana-2?pretty"
# Save the new "value".

# 2. Update the K8s secret with the new token value
kubectl create secret generic kibana-es-token \
  --from-literal=token="<new-value>" \
  --dry-run=client -o yaml | kubectl apply -f - -n <namespace>

# 3. Upgrade the release -- the checksum annotation on the Deployment detects the
#    secret change and triggers a rolling restart automatically
helm upgrade <release> . -f environments/<your-env>.yaml -n <namespace>

# 4. Wait for the rollout to complete, then delete the old token from ES
kubectl rollout status deployment/<release>-kibana -n <namespace>
curl -sf{{TLS_FLAG}} -u "elastic:${ELASTIC_PASSWORD}" \
  -X DELETE "$ES_URL/_security/service/elastic/kibana/credential/token/kibana-1?pretty"
```

Both tokens are valid simultaneously during the rollout — zero sessions are dropped.

## Values reference

| Value | Default | Description |
|-------|---------|-------------|
| `kibana.enabled` | `false` | Deploy Kibana in this release |
| `kibana.replicas` | `1` | Number of Kibana pods |
| `kibana.image.tag` | _(ES version)_ | Kibana image tag; must match ES major.minor |
| `kibana.serviceAccountToken.existingSecret` | `""` | **Required** when enabled. Key: `token` |
| `kibana.encryptionKeys.existingSecret` | `""` | Recommended. Keys: `security`, `savedObjects`, `reporting` |
| `kibana.antiAffinity` | `preferred` | Pod anti-affinity: `required` \| `preferred` \| `disabled` |
| `kibana.resources` | 500m/1Gi → 1000m/1Gi | CPU/memory requests and limits |
