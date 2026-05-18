# Implementation Plan — Phase 1: Core Security Foundation

## Automation Approach

AWS infrastructure (EKS cluster, KMS, ECR, SNS, IAM) is created with AWS CLI and eksctl — these are pre-Kubernetes resources that Helmfile cannot manage.

All Kubernetes workloads are deployed with a single Helmfile command. Helmfile handles release ordering via `needs:`, post-install configuration via `hooks:`, and values per chart via `values:`.

```
scripts/
  01_aws_infra.sh         ← AWS CLI: KMS, ECR, SNS, IAM, Pod Identity
  02_eks_cluster.sh       ← eksctl: cluster + node groups
  03_kubeconfig.sh        ← aws eks update-kubeconfig
  validate_phase1.sh      ← automated validation checks

helmfile/
  phase1/
    helmfile.yaml.gotmpl         ← all Phase 1 releases, ordering, hooks
    values/
      istio-base.yaml
      istiod.yaml
      spire.yaml
      consul.yaml
      vault.yaml
      keycloak.yaml
      opa.yaml
      gateway.yaml
      otel-collector.yaml
      loki.yaml
      grafana.yaml
    hooks/
      spire-register-entries.sh
      consul-seed-registries.sh
      consul-coredns-patch.sh
      vault-init.sh
      keycloak-configure.sh
      opa-load-policies.sh
```

**Run Phase 1:**
```bash
aws configure                              # MANUAL STEP 1
./scripts/01_aws_infra.sh
./scripts/02_eks_cluster.sh
./scripts/03_kubeconfig.sh
helmfile -f helmfile/phase1/helmfile.yaml.gotmpl sync
./scripts/validate_phase1.sh
```

---

## Manual Steps — Phase 1

---

> **MANUAL STEP 1 — AWS CLI Login**
>
> Run once before any scripts:
> ```bash
> aws configure
> # AWS Access Key ID:
> # AWS Secret Access Key:
> # Default region (e.g. us-east-1):
> # Output format: json
> ```
> Verify: `aws sts get-caller-identity`

---

> **MANUAL STEP 2 — ACM Certificate (HTTPS for Keycloak + Portal)**
>
> Required for ALB HTTPS. Cannot be fully automated without Route53.
>
> 1. AWS Console → **Certificate Manager** → **Request certificate**
> 2. Add domain names: `auth.firm.internal`, `portal.firm.internal`
> 3. Choose **DNS validation** → copy the CNAME records shown
> 4. Add CNAME records to your DNS provider
> 5. Wait for status **Issued** (5–15 min)
> 6. Copy the Certificate ARN — `01_aws_infra.sh` prompts for it
>
> If using Route53: add `--route53` flag to `01_aws_infra.sh` to automate this step.

---

> **MANUAL STEP 3 — Vault Recovery Keys**
>
> When Vault initialises for the first time (via the `vault-init.sh` hook),
> recovery keys are printed once to stdout. They are never stored automatically.
>
> ```
> Recovery Key 1: xxxx  ← store offline immediately
> Recovery Key 2: xxxx
> ...
> ```
>
> Store all 5 keys in a secure offline location (password manager, printed, locked).
> These are only needed if AWS KMS becomes unavailable.
> **Do not store in Git, S3, or anywhere accessible from the cluster.**

---

> **MANUAL STEP 4 — Duo Security Account (Phase 2 prep)**
>
> Create a Duo account now so Phase 2 has no blockers.
>
> 1. Sign up at https://duo.com
> 2. Admin Panel → **Applications** → **Protect an Application** → **Auth API**
> 3. Note: `Integration Key`, `Secret Key`, `API Hostname`
> 4. Store in Vault after Phase 1 completes:
>    ```bash
>    vault kv put secret/duo ikey=<value> skey=<value> host=<value>
>    ```

---

## AWS Infrastructure Scripts

### `scripts/01_aws_infra.sh`

Creates all AWS resources needed before the EKS cluster. Idempotent — safe to re-run.

```bash
#!/bin/bash
set -euo pipefail
source scripts/lib/common.sh

REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log "Creating KMS key for Vault auto-unseal..."
KMS_KEY_ID=$(aws kms create-key \
  --description "vault-unseal-agentic-security" \
  --query KeyMetadata.KeyId --output text 2>/dev/null || \
  aws kms describe-key --key-id alias/vault-unseal \
  --query KeyMetadata.KeyId --output text)
aws kms create-alias --alias-name alias/vault-unseal \
  --target-key-id $KMS_KEY_ID 2>/dev/null || true
save_env KMS_KEY_ID $KMS_KEY_ID

log "Creating ECR repositories..."
for svc in orchestrator-agent web-search-agent internal-data-agent \
           report-generation-agent email-agent security-gateway ciba-acp; do
  aws ecr describe-repositories --repository-names agentic/$svc 2>/dev/null || \
  aws ecr create-repository --repository-name agentic/$svc \
    --image-scanning-configuration scanOnPush=true
done

log "Creating SNS topics..."
CIBA_TOPIC=$(aws sns create-topic --name ciba-approvals --query TopicArn --output text)
ALERT_TOPIC=$(aws sns create-topic --name security-alerts --query TopicArn --output text)
save_env CIBA_SNS_TOPIC $CIBA_TOPIC
save_env ALERT_SNS_TOPIC $ALERT_TOPIC

log "Creating IAM roles for EKS Pod Identity..."
create_pod_identity_role "vault-unseal-role" \
  '{"Action":["kms:Decrypt","kms:DescribeKey"],"Resource":"arn:aws:kms:'$REGION':'$ACCOUNT_ID':key/'$KMS_KEY_ID'"}'
create_pod_identity_role "ciba-acp-role" \
  '{"Action":"sns:Publish","Resource":"'$CIBA_TOPIC'"}'

log "AWS infrastructure ready"
```

### `scripts/02_eks_cluster.sh`

```bash
#!/bin/bash
set -euo pipefail
source scripts/lib/common.sh

CLUSTER_NAME="agentic-security"
REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log "Creating EKS cluster..."
cat <<EOF | eksctl create cluster -f - --skip-cloudformation-updates
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: $CLUSTER_NAME
  region: $REGION
  version: "1.29"
addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: eks-pod-identity-agent
managedNodeGroups:
  - name: system
    instanceType: t3.medium
    minSize: 2
    maxSize: 2
    labels: {role: system}
    privateNetworking: true
  - name: application
    instanceType: m5.2xlarge
    minSize: 3
    maxSize: 6
    labels: {role: application}
    privateNetworking: true
  - name: observability
    instanceType: m5.xlarge
    minSize: 2
    maxSize: 2
    labels: {role: observability}
    privateNetworking: true
EOF

log "Binding EKS Pod Identity associations..."
aws eks create-pod-identity-association \
  --cluster-name $CLUSTER_NAME \
  --namespace infra --service-account vault \
  --role-arn arn:aws:iam::$ACCOUNT_ID:role/vault-unseal-role
aws eks create-pod-identity-association \
  --cluster-name $CLUSTER_NAME \
  --namespace infra --service-account ciba-acp \
  --role-arn arn:aws:iam::$ACCOUNT_ID:role/ciba-acp-role

log "EKS cluster ready"
```

### `scripts/03_kubeconfig.sh`

```bash
#!/bin/bash
set -euo pipefail
CLUSTER_NAME="agentic-security"
REGION=$(aws configure get region)
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION
kubectl get nodes
```

---

## Helmfile — Phase 1

### `helmfile/phase1/helmfile.yaml.gotmpl`

```yaml
repositories:
  - name: istio
    url: https://istio-release.storage.googleapis.com/charts
  - name: spiffe
    url: https://spiffe.github.io/helm-charts-hardened
  - name: hashicorp
    url: https://helm.releases.hashicorp.com
  - name: bitnami
    url: https://charts.bitnami.com/bitnami
  - name: opa
    url: https://open-policy-agent.github.io/kube-mgmt/charts
  - name: open-telemetry
    url: https://open-telemetry.github.io/opentelemetry-helm-charts
  - name: grafana
    url: https://grafana.github.io/helm-charts

helmDefaults:
  wait: true
  timeout: 300
  createNamespace: true

releases:

  # ── Istio ────────────────────────────────────────────────────────────────

  - name: istio-base
    namespace: istio-system
    chart: istio/base
    values:
      - values/istio-base.yaml

  - name: istiod
    namespace: istio-system
    chart: istio/istiod
    needs:
      - istio-system/istio-base
    values:
      - values/istiod.yaml
    hooks:
      - events: ["postsync"]
        command: "kubectl"
        args:
          - apply
          - -f
          - helmfile/phase1/manifests/peer-authentication-strict.yaml

  # ── SPIRE ─────────────────────────────────────────────────────────────────

  - name: spire
    namespace: spire-system
    chart: spiffe/spire
    needs:
      - istio-system/istiod
    values:
      - values/spire.yaml
    hooks:
      - events: ["postsync"]
        command: "bash"
        args: ["helmfile/phase1/hooks/spire-register-entries.sh"]

  # ── Consul ────────────────────────────────────────────────────────────────

  - name: consul
    namespace: infra
    chart: hashicorp/consul
    needs:
      - spire-system/spire
    values:
      - values/consul.yaml
    hooks:
      - events: ["postsync"]
        command: "bash"
        args: ["helmfile/phase1/hooks/consul-seed-registries.sh"]
      - events: ["postsync"]
        command: "bash"
        args: ["helmfile/phase1/hooks/consul-coredns-patch.sh"]

  # ── Vault ─────────────────────────────────────────────────────────────────

  - name: vault
    namespace: infra
    chart: hashicorp/vault
    needs:
      - infra/consul
    values:
      - values/vault.yaml
    hooks:
      - events: ["postsync"]
        command: "bash"
        args: ["helmfile/phase1/hooks/vault-init.sh"]

  # ── Keycloak ──────────────────────────────────────────────────────────────

  - name: keycloak
    namespace: infra
    chart: bitnami/keycloak
    needs:
      - infra/vault
    values:
      - values/keycloak.yaml
    hooks:
      - events: ["postsync"]
        command: "bash"
        args: ["helmfile/phase1/hooks/keycloak-configure.sh"]

  # ── CIBA ACP ──────────────────────────────────────────────────────────────

  - name: ciba-acp
    namespace: infra
    chart: ./charts/ciba-acp
    needs:
      - infra/keycloak
    values:
      - values/ciba-acp.yaml

  # ── OPA ───────────────────────────────────────────────────────────────────

  - name: opa
    namespace: infra
    chart: opa/opa
    needs:
      - infra/consul
    values:
      - values/opa.yaml
    hooks:
      - events: ["postsync"]
        command: "bash"
        args: ["helmfile/phase1/hooks/opa-load-policies.sh"]

  # ── Redis (rate limiting) ─────────────────────────────────────────────────

  - name: redis
    namespace: infra
    chart: bitnami/redis
    values:
      - values/redis.yaml

  # ── Security Gateway ──────────────────────────────────────────────────────

  - name: security-gateway
    namespace: infra
    chart: ./charts/security-gateway
    needs:
      - infra/opa
      - infra/consul
      - infra/redis
      - spire-system/spire
    values:
      - values/gateway.yaml

  # ── Observability ─────────────────────────────────────────────────────────

  - name: otel-collector
    namespace: observability
    chart: open-telemetry/opentelemetry-collector
    values:
      - values/otel-collector.yaml

  - name: loki
    namespace: observability
    chart: grafana/loki-stack
    needs:
      - observability/otel-collector
    values:
      - values/loki.yaml

  - name: grafana
    namespace: observability
    chart: grafana/grafana
    needs:
      - observability/loki
    values:
      - values/grafana.yaml

  # ── Agents ────────────────────────────────────────────────────────────────

  - name: agents
    namespace: agents
    chart: ./charts/agents
    needs:
      - infra/security-gateway
      - infra/keycloak
      - spire-system/spire
      - observability/otel-collector
    values:
      - values/agents.yaml
```

---

## Key Hook Scripts

### `helmfile/phase1/hooks/consul-seed-registries.sh`

Runs automatically after Consul is deployed via the `postsync` hook.

```bash
#!/bin/bash
set -euo pipefail
CONSUL_POD=$(kubectl get pod -n infra -l app=consul -o jsonpath='{.items[0].metadata.name}')

# Agent registry
declare -A AGENTS=(
  ["orchestrator-agent"]='{"role":"agent-orchestrator","allowed_tools":["web_search","query_internal_db","generate_report","send_email"],"max_data_classification":"confidential","status":"active"}'
  ["web-search-agent"]='{"role":"agent-researcher-public","allowed_tools":["web_search"],"max_data_classification":"public","status":"active"}'
  ["internal-data-agent"]='{"role":"agent-researcher-internal","allowed_tools":["query_internal_db"],"max_data_classification":"confidential","status":"active"}'
  ["report-generation-agent"]='{"role":"agent-writer","allowed_tools":["generate_report"],"max_data_classification":"confidential","status":"active"}'
  ["email-agent"]='{"role":"agent-communicator","allowed_tools":["send_email"],"max_data_classification":"confidential","status":"active"}'
)
for agent in "${!AGENTS[@]}"; do
  kubectl exec -n infra $CONSUL_POD -- consul kv put agents/$agent "${AGENTS[$agent]}"
done

# Tool registry
declare -A TOOLS=(
  ["web_search"]='{"mcp_endpoint":"https://web-search.tools.svc.cluster.local","allowed_callers":["web-search-agent"],"data_classification":"public","blast_radius":"low","status":"active"}'
  ["query_internal_db"]='{"mcp_endpoint":"https://internal-db.tools.svc.cluster.local","allowed_callers":["internal-data-agent"],"data_classification":"confidential","blast_radius":"medium","status":"active"}'
  ["generate_report"]='{"mcp_endpoint":"https://report-gen.tools.svc.cluster.local","allowed_callers":["report-generation-agent"],"data_classification":"confidential","blast_radius":"low","status":"active"}'
  ["send_email"]='{"mcp_endpoint":"https://email.tools.svc.cluster.local","allowed_callers":["email-agent"],"data_classification":"confidential","blast_radius":"high","status":"active"}'
)
for tool in "${!TOOLS[@]}"; do
  kubectl exec -n infra $CONSUL_POD -- consul kv put tools/$tool "${TOOLS[$tool]}"
done
echo "Consul registries seeded"
```

### `helmfile/phase1/hooks/vault-init.sh`

```bash
#!/bin/bash
set -euo pipefail
kubectl wait --for=condition=ready pod vault-0 -n infra --timeout=120s

# Check if already initialised
INIT=$(kubectl exec -n infra vault-0 -- vault status -format=json 2>/dev/null \
  | jq -r '.initialized')
if [ "$INIT" = "true" ]; then
  echo "Vault already initialised — skipping"
  exit 0
fi

echo "================================================"
echo "MANUAL STEP 3: Save the recovery keys below NOW"
echo "Store offline before pressing any key to continue"
echo "================================================"
kubectl exec -n infra vault-0 -- vault operator init \
  -recovery-shares=5 -recovery-threshold=3
read -p "Press ENTER only after saving recovery keys..."

kubectl exec -n infra vault-0 -- vault auth enable kubernetes
kubectl exec -n infra vault-0 -- vault secrets enable -path=secret kv-v2
echo "Vault initialised"
```

### `helmfile/phase1/hooks/keycloak-configure.sh`

```bash
#!/bin/bash
set -euo pipefail
KEYCLOAK_URL="http://$(kubectl get svc keycloak -n infra \
  -o jsonpath='{.spec.clusterIP}'):80"
ADMIN_PASS=$(kubectl get secret keycloak -n infra \
  -o jsonpath='{.data.admin-password}' | base64 -d)

# Get admin token
TOKEN=$(curl -sf -X POST \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&username=admin&password=$ADMIN_PASS&grant_type=password" \
  | jq -r '.access_token')

# Create realm with CIBA
curl -sf -X POST "$KEYCLOAK_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"realm":"firm-internal","enabled":true}'

curl -sf -X PUT "$KEYCLOAK_URL/admin/realms/firm-internal" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"attributes":{"cibaBackchannelTokenDeliveryMode":"poll","cibaExpiresIn":"120","cibaInterval":"5"}}'

for role in analyst admin viewer; do
  curl -sf -X POST "$KEYCLOAK_URL/admin/realms/firm-internal/roles" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"$role\"}"
done
echo "Keycloak realm and CIBA configured"
```

---

## Validation

### `scripts/validate_phase1.sh`

```bash
#!/bin/bash
set -euo pipefail
PASS=0; FAIL=0

check() {
  if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; ((PASS++))
  else echo "FAIL: $1"; ((FAIL++)); fi
}

check "All nodes Ready" \
  "kubectl get nodes --no-headers | awk '{print \$2}' | grep -v Ready | wc -l | grep -q '^0$'"
check "Istio strict mTLS" \
  "kubectl get peerauthentication -A --no-headers | grep -q STRICT"
check "SPIRE issuing SVIDs" \
  "kubectl exec -n agents deploy/orchestrator-agent -- \
   /opt/spire/bin/spire-agent api fetch x509 2>&1 | grep -q 'spiffe://'"
check "Consul agent registry populated" \
  "kubectl exec -n infra consul-server-0 -- consul kv get agents/web-search-agent | grep -q status"
check "Vault unsealed via KMS" \
  "kubectl exec -n infra vault-0 -- vault status -format=json | jq -r '.sealed' | grep -q false"
check "Keycloak CIBA enabled" \
  "curl -s http://$(kubectl get svc keycloak -n infra -o jsonpath='{.spec.clusterIP}')/realms/firm-internal \
   | jq -r '.attributes.cibaBackchannelTokenDeliveryMode' | grep -q poll"
check "OPA denying unknown agent" \
  "curl -s -X POST http://opa.infra.svc.cluster.local:8181/v1/data/agentic/baseline/allow \
   -d '{\"input\":{\"agent_type\":\"unknown\",\"tool\":\"web_search\"}}' \
   | jq -r '.result' | grep -q false"
check "Audit logs flowing to Loki" \
  "curl -s http://loki.observability.svc.cluster.local:3100/loki/api/v1/labels \
   | jq -r '.data[]' | grep -q agent_id"

echo; echo "Phase 1: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && echo "✓ Phase 1 COMPLETE" || exit 1
```
