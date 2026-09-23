# Kibana Setup Guide

This guide covers integrating Kibana with the Elasticsearch cluster deployed by this
Helm chart. Two integration paths are supported — pick the one that matches your
deployment topology:

| Path | When to use |
|------|-------------|
| **[A] In-chart Kibana** | Kibana runs in the **same cluster and namespace** as ES, managed by this Helm release (`kibana.enabled=true`) |
| **[B] External Kibana** | Kibana runs in a **different cluster or namespace**, managed independently |

Both paths use the same ES service account token mechanism. Steps that differ are
called out under each path.

---

## Prerequisites

Applies to both paths:

1. ES cluster is healthy — all pods Running/Ready:
   ```bash
   kubectl get pods -n <es-namespace>
   ```
2. You have `elastic` credentials from the post-install runbook:
   ```bash
   helm get notes <release> -n <es-namespace>
   ```
3. Set shell variables for the steps below:
   ```bash
   ES_NAMESPACE=<es-namespace>
   RELEASE=<release-name>

   # Retrieve the elastic password
   ELASTIC_PASSWORD=$(kubectl get secret ${RELEASE}-bootstrap \
     -n ${ES_NAMESPACE} -o jsonpath='{.data.ELASTIC_PASSWORD}' | base64 -d)

   # ES URL — adjust TLS flag based on your setup
   # tls.enabled=true and istio.enabled=false:
   ES_URL="https://${RELEASE}-ingest.${ES_NAMESPACE}.svc:9200"
   CURL_TLS="-k"   # or --cacert /path/to/ca.crt for strict validation
   # istio.enabled=true (Istio handles mTLS, plain HTTP inside pod):
   # ES_URL="http://${RELEASE}-ingest.${ES_NAMESPACE}.svc:9200"
   # CURL_TLS=""
   ```

---

## Common Step 1 — Create the ES service account token

This step is identical for both integration paths. Run it from a pod or machine
that can reach the ES ingest service.

```bash
curl -sf ${CURL_TLS} -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST "${ES_URL}/_security/service/elastic/kibana/credential/token/kibana-1?pretty"
```

Example response:

```json
{
  "created": true,
  "token": {
    "name": "kibana-1",
    "value": "AAEAAWVsYXN0aWMva2liYW5hL2..."
  }
}
```

> **Save the `"value"` field immediately.**
> ES stores only the SHA-256 hash — the plaintext token is shown exactly once.
> If you lose it, create a new token (`kibana-2`) and delete the old one.

Verify the token works:

```bash
curl -sf ${CURL_TLS} \
  -H "Authorization: Bearer <value-from-above>" \
  "${ES_URL}/_security/_authenticate?pretty"
# Expected: "username": "elastic/kibana", "roles": []
```

---

## Path A — In-chart Kibana (same cluster, `kibana.enabled=true`)

Kibana is deployed as a Deployment, Service, ConfigMap, and NetworkPolicy within
this Helm release, in the same namespace as ES.

**Resources created when enabled:**

| Resource | Name | Notes |
|----------|------|-------|
| Deployment | `<release>-kibana` | RollingUpdate, maxUnavailable=0 |
| Service | `<release>-kibana` | ClusterIP port 5601 |
| ConfigMap | `<release>-kibana-config` | kibana.yml (server + SSL config) |
| NetworkPolicy | `<release>-kibana` | egress → ES:9200 + DNS; ingress → 5601 |

**ES connection inside the chart:**
- `istio.enabled=true` → `http://<release>-ingest.<namespace>.svc:9200` (Envoy mTLS)
- `istio.enabled=false` → `https://<release>-ingest.<namespace>.svc:9200` + CA cert mounted

### Step A-1 — Create the K8s token secret

```bash
kubectl create secret generic kibana-es-token \
  --from-literal=token="<value-from-common-step-1>" \
  -n ${ES_NAMESPACE}
```

### Step A-2 — Create encryption key secrets (required for production)

Kibana needs three stable random keys for encrypted sessions, saved objects
(alerts, connectors), and reporting. Without them, Kibana generates random keys
on every restart — all sessions are invalidated and encrypted saved objects
cannot be decrypted after a pod restart or rolling update.

```bash
kubectl create secret generic kibana-encryption-keys \
  --from-literal=security="$(openssl rand -hex 32)" \
  --from-literal=savedObjects="$(openssl rand -hex 32)" \
  --from-literal=reporting="$(openssl rand -hex 32)" \
  -n ${ES_NAMESPACE}
```

> **Store these in a secrets manager** (Vault, AWS Secrets Manager, etc.) before
> clearing terminal history. If lost, existing encrypted saved objects cannot be
> recovered — you must delete and recreate them.

### Step A-3 — Enable Kibana via helm upgrade

```bash
helm upgrade ${RELEASE} . \
  -f environments/<your-env>.yaml \
  --set kibana.enabled=true \
  --set kibana.serviceAccountToken.existingSecret=kibana-es-token \
  --set kibana.encryptionKeys.existingSecret=kibana-encryption-keys \
  -n ${ES_NAMESPACE}
```

Or commit to your environment overlay and upgrade without `--set`:

```yaml
# environments/<your-env>.yaml
kibana:
  enabled: true
  serviceAccountToken:
    existingSecret: "kibana-es-token"
  encryptionKeys:
    existingSecret: "kibana-encryption-keys"
```

### Step A-4 — Access Kibana

```bash
# Wait for rollout
kubectl rollout status deployment/${RELEASE}-kibana -n ${ES_NAMESPACE}

# Port-forward for local access
kubectl port-forward svc/${RELEASE}-kibana 5601:5601 -n ${ES_NAMESPACE}
# Open: http://localhost:5601
# Log in as: elastic / ${ELASTIC_PASSWORD}
```

For external access, add an Istio VirtualService (when `istio.enabled=true`) or
a Kubernetes Ingress pointing at the `<release>-kibana` Service on port 5601.

### Token rotation — in-chart (zero-downtime)

ES service accounts support multiple simultaneous tokens:

```bash
# 1. Create a new token in ES
curl -sf ${CURL_TLS} -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST "${ES_URL}/_security/service/elastic/kibana/credential/token/kibana-2?pretty"
# Save the new "value".

# 2. Patch the K8s secret with the new value
kubectl create secret generic kibana-es-token \
  --from-literal=token="<new-value>" \
  --dry-run=client -o yaml | kubectl apply -f - -n ${ES_NAMESPACE}

# 3. Upgrade the release — the checksum annotation on the Deployment detects
#    the secret change and triggers a rolling restart automatically
helm upgrade ${RELEASE} . -f environments/<your-env>.yaml -n ${ES_NAMESPACE}

# 4. Wait for rollout, then revoke the old token
kubectl rollout status deployment/${RELEASE}-kibana -n ${ES_NAMESPACE}
curl -sf ${CURL_TLS} -u "elastic:${ELASTIC_PASSWORD}" \
  -X DELETE "${ES_URL}/_security/service/elastic/kibana/credential/token/kibana-1?pretty"
```

Both tokens are valid simultaneously during the rollout — zero sessions are dropped.

---

## Path B — External Kibana (different cluster or namespace)

Kibana runs outside this Helm release — in a different cluster, a different
namespace, or managed by an independent `elastic/kibana` Helm chart. This chart
manages only the ES side; Kibana configuration is your responsibility.

Set `kibana.enabled: false` (the default) — this chart renders no Kibana resources.

### Step B-1 — Expose the ES ingest service externally

The ingest Service is ClusterIP by default, reachable only inside the ES cluster.
Choose one exposure method:

**Option 1: Istio Gateway + VirtualService** (recommended for OpenShift with Istio)

Create a Gateway and VirtualService in the ES cluster that routes external HTTPS
traffic to the ingest service. Example:

```yaml
# es-gateway.yaml (apply in the ES cluster)
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: es-gateway
  namespace: <es-namespace>
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 9200
        name: https-es
        protocol: HTTPS
      tls:
        mode: PASSTHROUGH   # let Kibana verify the ES cert end-to-end
      hosts:
        - es.<your-domain>
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: es-ingest
  namespace: <es-namespace>
spec:
  hosts:
    - es.<your-domain>
  gateways:
    - es-gateway
  tls:
    - match:
        - port: 9200
          sniHosts:
            - es.<your-domain>
      route:
        - destination:
            host: <release>-ingest.<es-namespace>.svc.cluster.local
            port:
              number: 9200
```

**Option 2: LoadBalancer service** (cloud or on-prem with MetalLB)

```bash
# Patch the ingest service to type LoadBalancer (apply in the ES cluster)
kubectl patch svc ${RELEASE}-ingest -n ${ES_NAMESPACE} \
  -p '{"spec":{"type":"LoadBalancer"}}'

# Get the external IP once provisioned
kubectl get svc ${RELEASE}-ingest -n ${ES_NAMESPACE} \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

After either option, record the ES endpoint that Kibana will use:

```bash
ES_EXTERNAL_URL="https://es.<your-domain>:9200"   # Istio Gateway
# or
ES_EXTERNAL_URL="https://<loadbalancer-ip>:9200"  # LoadBalancer
```

### Step B-2 — Distribute the ES CA certificate to the Kibana cluster

Kibana must trust the ES TLS certificate. Extract the CA from the ES cluster and
create it in the Kibana cluster:

```bash
# Run against the ES cluster
kubectl get secret ${RELEASE}-es-tls -n ${ES_NAMESPACE} \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > es-ca.crt

# Run against the Kibana cluster (switch kubeconfig context first if needed)
kubectl create secret generic es-ca-cert \
  --from-file=ca.crt=es-ca.crt \
  -n <kibana-namespace>

rm es-ca.crt   # don't leave the cert on disk
```

> Skip this step only if `istio.enabled=false` AND you are using a CA cert from a
> trusted public CA — in that case Kibana trusts it automatically via the system
> trust store.

### Step B-3 — Create the token secret in the Kibana cluster

```bash
# Run against the Kibana cluster
kubectl create secret generic kibana-es-token \
  --from-literal=token="<value-from-common-step-1>" \
  -n <kibana-namespace>
```

### Step B-4 — Create encryption key secrets in the Kibana cluster

Same requirement as Path A — stable keys for sessions, saved objects, and reporting:

```bash
# Run against the Kibana cluster
kubectl create secret generic kibana-encryption-keys \
  --from-literal=security="$(openssl rand -hex 32)" \
  --from-literal=savedObjects="$(openssl rand -hex 32)" \
  --from-literal=reporting="$(openssl rand -hex 32)" \
  -n <kibana-namespace>
```

> **Store these in a secrets manager before clearing terminal history.**

### Step B-5 — Configure the external Kibana

**Using the `elastic/kibana` Helm chart:**

```yaml
# kibana-values.yaml
imageTag: "<must match ES major.minor, e.g. 8.19.18>"

elasticsearchHosts: "<ES_EXTERNAL_URL>"   # from Step B-1

elasticsearchCertificateSecret: "es-ca-cert"          # from Step B-2
elasticsearchCertificateAuthoritiesFile: "ca.crt"

extraEnvs:
  - name: ELASTICSEARCH_SERVICEACCOUNTTOKEN
    valueFrom:
      secretKeyRef:
        name: kibana-es-token      # from Step B-3
        key: token
  - name: XPACK_SECURITY_ENCRYPTIONKEY
    valueFrom:
      secretKeyRef:
        name: kibana-encryption-keys   # from Step B-4
        key: security
  - name: XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY
    valueFrom:
      secretKeyRef:
        name: kibana-encryption-keys
        key: savedObjects
  - name: XPACK_REPORTING_ENCRYPTIONKEY
    valueFrom:
      secretKeyRef:
        name: kibana-encryption-keys
        key: reporting
```

```bash
helm repo add elastic https://helm.elastic.co
helm upgrade --install kibana elastic/kibana \
  -f kibana-values.yaml \
  -n <kibana-namespace>
```

**Using a standalone `kibana.yml`** (non-Helm deployment):

```yaml
server.host: "0.0.0.0"
server.port: 5601

elasticsearch.hosts: ["<ES_EXTERNAL_URL>"]
elasticsearch.ssl.certificateAuthorities: ["/path/to/ca.crt"]
elasticsearch.ssl.verificationMode: certificate

# Inject these as environment variables rather than hardcoding in the file:
# ELASTICSEARCH_SERVICEACCOUNTTOKEN=<token-value>
# XPACK_SECURITY_ENCRYPTIONKEY=<32-char-key>
# XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=<32-char-key>
# XPACK_REPORTING_ENCRYPTIONKEY=<32-char-key>

telemetry.optIn: false
telemetry.enabled: false
```

### Step B-6 — Verify

```bash
# From the Kibana cluster, check Kibana status
kubectl rollout status deployment/kibana -n <kibana-namespace>

# Access Kibana
kubectl port-forward svc/kibana 5601:5601 -n <kibana-namespace>
# Open: http://localhost:5601
# Log in as: elastic / <ELASTIC_PASSWORD>

# Confirm ES connection in the Kibana UI: Stack Monitoring → Clusters
# or via API:
curl -sf http://localhost:5601/api/status | jq '.status.overall.level'
# Expected: "available"
```

### Token rotation — external Kibana (zero-downtime)

```bash
# 1. Create a new token in ES (run against ES cluster)
curl -sf ${CURL_TLS} -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST "${ES_URL}/_security/service/elastic/kibana/credential/token/kibana-2?pretty"
# Save the new "value".

# 2. Update the token secret in the Kibana cluster
kubectl create secret generic kibana-es-token \
  --from-literal=token="<new-value>" \
  --dry-run=client -o yaml | kubectl apply -f - -n <kibana-namespace>

# 3. Trigger a rolling restart of Kibana pods to pick up the new token
#    (elastic/kibana chart):
helm upgrade kibana elastic/kibana -f kibana-values.yaml -n <kibana-namespace>
#    (standalone deployment):
kubectl rollout restart deployment/kibana -n <kibana-namespace>

# 4. Wait for rollout, then revoke the old token in ES
kubectl rollout status deployment/kibana -n <kibana-namespace>
curl -sf ${CURL_TLS} -u "elastic:${ELASTIC_PASSWORD}" \
  -X DELETE "${ES_URL}/_security/service/elastic/kibana/credential/token/kibana-1?pretty"
```

Both tokens are valid simultaneously during the rollout — zero sessions are dropped.

---

## Values reference (Path A — in-chart Kibana only)

| Value | Default | Description |
|-------|---------|-------------|
| `kibana.enabled` | `false` | Deploy Kibana in this release |
| `kibana.replicas` | `1` | Number of Kibana pods |
| `kibana.image.tag` | _(ES version)_ | Kibana image tag; must match ES major.minor |
| `kibana.serviceAccountToken.existingSecret` | `""` | **Required** when enabled. Key: `token` |
| `kibana.encryptionKeys.existingSecret` | `""` | Recommended. Keys: `security`, `savedObjects`, `reporting` |
| `kibana.antiAffinity` | `preferred` | Pod anti-affinity: `required` \| `preferred` \| `disabled` |
| `kibana.resources` | 500m/1Gi → 1000m/1Gi | CPU/memory requests and limits |
