#!/bin/bash
set -euo pipefail
source scripts/lib/common.sh
load_env

export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CLUSTER_NAME="agentic-security"
REGION=$(aws configure get region)

# ── Step 1: Check node capacity ───────────────────────────────────────────────
log "Checking node capacity for Ollama CPU workloads..."

SYSTEM_NODES=$(kubectl get nodes -l role=system --no-headers | wc -l)
log "System nodegroup has $SYSTEM_NODES node(s)"

# llama3.1:8b needs ~6GB RAM — two instances = 12GB minimum on system nodes
# t3.medium = 4GB, t3.large = 8GB, t3.xlarge = 16GB
NODE_TYPE=$(kubectl get nodes -l role=system \
  -o jsonpath='{.items[0].metadata.labels.beta\.kubernetes\.io/instance-type}' 2>/dev/null || \
  kubectl get nodes -l role=system \
  -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")

log "System node type: $NODE_TYPE"

if [[ "$NODE_TYPE" == "t3.medium" ]]; then
  log "WARNING: t3.medium (4GB) is too small for llama3.1:8b (needs 6GB)."
  log "Scaling system nodegroup to t3.xlarge-equivalent — adding nodes..."
  eksctl scale nodegroup \
    --cluster $CLUSTER_NAME \
    --region $REGION \
    --name system \
    --nodes 4
  log "Waiting for new nodes to be Ready..."
  sleep 30
  kubectl wait nodes -l role=system --for=condition=Ready --timeout=180s
fi

# ── Step 2: Create Duo credentials Kubernetes secret ─────────────────────────
log "Syncing Duo credentials from Vault to Kubernetes secret..."

kubectl exec -n infra vault-0 -- vault kv get -format=json secret/duo \
  > /tmp/duo-vault.json 2>/dev/null || {
  die "Duo credentials not found in Vault. Run: vault kv put secret/duo ikey=<> skey=<> host=<>"
}

DUO_IKEY=$(jq -r '.data.data.ikey' /tmp/duo-vault.json)
DUO_SKEY=$(jq -r '.data.data.skey' /tmp/duo-vault.json)
DUO_HOST=$(jq -r '.data.data.host' /tmp/duo-vault.json)
rm -f /tmp/duo-vault.json

kubectl create secret generic duo-credentials \
  -n infra \
  --from-literal=DUO_IKEY="$DUO_IKEY" \
  --from-literal=DUO_SKEY="$DUO_SKEY" \
  --from-literal=DUO_HOST="$DUO_HOST" \
  --dry-run=client -o yaml | kubectl apply -f -

log "duo-credentials secret created in infra namespace"

# ── Step 3: Run helmfile sync ─────────────────────────────────────────────────
log "Running helmfile Phase 2 sync..."
log "NOTE: Ollama will pull llama3.1:8b (~4.7GB) — this may take 10-15 min on first run"

helmfile -f helmfile/phase2/helmfile.yaml.gotmpl sync

log "Helmfile Phase 2 sync complete"

# ── Step 4: Validate ──────────────────────────────────────────────────────────
log "Running Phase 2 validation..."
./scripts/validate_phase2.sh
