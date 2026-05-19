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
    # Write keys to a file immediately — never rely on terminal scroll
    KEYS_FILE="${HOME}/vault-init-keys-$(date +%Y%m%d-%H%M%S).txt"
    echo "$INIT_OUT" > "$KEYS_FILE"
    chmod 600 "$KEYS_FILE"

    echo "$INIT_OUT"
    echo ""
    echo "=========================================================="
    echo "  KEYS WRITTEN TO: ${KEYS_FILE}"
    echo "  Move this file to a password manager then DELETE it."
    echo "  KMS handles day-to-day unseal — recovery keys are for"
    echo "  disaster recovery only (KMS key loss/deletion)."
    echo "=========================================================="
    echo ""

    # Save root token to scripts/.env for use by subsequent hooks
    ROOT_TOKEN=$(echo "$INIT_OUT" | grep "Initial Root Token:" | awk '{print $NF}')
    SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts" && pwd)"
    grep -v "^VAULT_ROOT_TOKEN=" "${SCRIPTS_DIR}/.env" 2>/dev/null > "${SCRIPTS_DIR}/.env.tmp" || true
    echo "VAULT_ROOT_TOKEN=${ROOT_TOKEN}" >> "${SCRIPTS_DIR}/.env.tmp"
    mv "${SCRIPTS_DIR}/.env.tmp" "${SCRIPTS_DIR}/.env"

    # Also persist in a K8s Secret as a second safety net
    kubectl create secret generic vault-init-keys \
      --from-literal=init-output="$INIT_OUT" \
      -n infra --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
    echo "Keys also stored in K8s Secret 'vault-init-keys' (infra namespace)."
    echo "  kubectl get secret vault-init-keys -n infra -o jsonpath='{.data.init-output}' | base64 -d"
    echo "  kubectl delete secret vault-init-keys -n infra   # run this after saving"
    echo ""

    # Block until operator confirms keys are saved
    if [ -t 0 ]; then
      read -r -p ">>> Press Enter ONLY after you have saved ALL 5 recovery keys and the root token: "
    else
      echo "WARNING: Non-interactive shell — retrieve keys from ${KEYS_FILE} before continuing."
      echo "Sleeping 60s to allow log capture..."
      sleep 60
    fi
  fi
fi

echo "Waiting for vault-0 to become Ready (KMS auto-unseal in progress)..."
kubectl wait pod vault-0 -n infra --for=condition=Ready --timeout=300s

# Join followers to the Raft cluster (retry_join in config handles this passively,
# but explicit join here ensures it completes before we proceed)
for peer in vault-1 vault-2; do
  echo "Joining ${peer} to Raft cluster..."
  kubectl exec -n infra "${peer}" -- vault operator raft join http://vault-0.vault-internal:8200 2>/dev/null || true
done

echo "Waiting for vault-1 and vault-2 to become Ready (KMS unseal in progress)..."
kubectl wait pod vault-1 vault-2 -n infra --for=condition=Ready --timeout=180s

# Enable Kubernetes auth backend
kubectl exec -n infra vault-0 -- vault auth enable kubernetes 2>/dev/null || true

# Enable KV v2 secrets engine
kubectl exec -n infra vault-0 -- vault secrets enable -path=secret kv-v2 2>/dev/null || true

echo "Vault initialised and configured"
