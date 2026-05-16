#!/bin/bash
set -euo pipefail

echo "Waiting for SPIRE server pod to be ready..."
kubectl wait pod spire-server-0 -n spire-system \
  --for=condition=Ready --timeout=180s

SPIRE_SERVER_POD="spire-server-0"

register() {
  local spiffe_id="$1" parent_id="$2" shift shift
  shift; shift
  local selectors=("$@")
  local selector_args=()
  for s in "${selectors[@]}"; do
    selector_args+=(-selector "$s")
  done
  kubectl exec -n spire-system "$SPIRE_SERVER_POD" -- \
    /opt/spire/bin/spire-server entry create \
    -spiffeID "$spiffe_id" \
    -parentID "$parent_id" \
    "${selector_args[@]}" 2>/dev/null || true
}

NODE_ID="spiffe://firm.internal/k8s-node"

# Agent workloads
register "spiffe://firm.internal/agent/orchestrator"    "$NODE_ID" "k8s:ns:agents" "k8s:sa:orchestrator-agent"
register "spiffe://firm.internal/agent/web-search"      "$NODE_ID" "k8s:ns:agents" "k8s:sa:web-search-agent"
register "spiffe://firm.internal/agent/internal-data"   "$NODE_ID" "k8s:ns:agents" "k8s:sa:internal-data-agent"
register "spiffe://firm.internal/agent/report-gen"      "$NODE_ID" "k8s:ns:agents" "k8s:sa:report-generation-agent"
register "spiffe://firm.internal/agent/email"           "$NODE_ID" "k8s:ns:agents" "k8s:sa:email-agent"

# Infrastructure workloads
register "spiffe://firm.internal/infra/security-gateway" "$NODE_ID" "k8s:ns:infra" "k8s:sa:security-gateway"
register "spiffe://firm.internal/infra/ciba-acp"         "$NODE_ID" "k8s:ns:infra" "k8s:sa:ciba-acp"
register "spiffe://firm.internal/infra/vault"            "$NODE_ID" "k8s:ns:infra" "k8s:sa:vault"

echo "SPIRE entries registered"
