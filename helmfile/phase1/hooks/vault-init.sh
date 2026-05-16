#!/bin/bash
set -euo pipefail

echo "Waiting for vault-0 to be Running..."
for i in $(seq 1 60); do
  PHASE=$(kubectl get pod vault-0 -n infra -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$PHASE" = "Running" ] && break
  echo "  vault-0 phase: ${PHASE:-pending} (attempt $i/60)"
  sleep 5
done

# Give vault listener time to start accepting connections
sleep 10

INIT=$(kubectl exec -n infra vault-0 -- vault status -format=json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['initialized'])" 2>/dev/null \
  || echo "false")

if [ "$INIT" = "True" ] || [ "$INIT" = "true" ]; then
  echo "Vault already initialised — skipping init"
else
  echo "Initialising Vault with KMS auto-unseal (recovery-shares=5, threshold=3)..."
  INIT_OUT=$(kubectl exec -n infra vault-0 -- vault operator init \
    -recovery-shares=5 \
    -recovery-threshold=3 2>&1) || true
  if echo "$INIT_OUT" | grep -q "already initialized"; then
    echo "Vault already initialized — continuing"
  else
    echo "$INIT_OUT"
    echo ""
    echo "=========================================================="
    echo "  SAVE THE RECOVERY KEYS ABOVE IN A PASSWORD MANAGER NOW"
    echo "  KMS handles day-to-day unseal — recovery keys are for"
    echo "  disaster recovery only (KMS key loss/deletion)."
    echo "=========================================================="
  fi
fi

echo "Waiting for vault-0 to become Ready (KMS auto-unseal in progress)..."
kubectl wait pod vault-0 -n infra --for=condition=Ready --timeout=300s

# Enable Kubernetes auth backend
kubectl exec -n infra vault-0 -- vault auth enable kubernetes 2>/dev/null || true

# Enable KV v2 secrets engine
kubectl exec -n infra vault-0 -- vault secrets enable -path=secret kv-v2 2>/dev/null || true

echo "Vault initialised and configured"
