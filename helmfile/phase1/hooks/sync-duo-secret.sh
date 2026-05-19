#!/bin/bash
# Reads Duo credentials from Vault and creates the duo-credentials k8s secret.
# Runs as a presync hook on ciba-acp. If Duo is not in Vault yet, creates an
# empty secret so the pod starts — Duo push will be inactive until creds are added.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../scripts" && pwd)"
source "${SCRIPTS_DIR}/lib/common.sh"
load_env

VAULT_TOKEN="${VAULT_ROOT_TOKEN:-}"

# Fall back to token file if not in .env
if [ -z "$VAULT_TOKEN" ]; then
  TOKEN_FILE=$(ls "${HOME}"/vault-init-keys-*.txt 2>/dev/null | head -1 || true)
  if [ -n "$TOKEN_FILE" ]; then
    VAULT_TOKEN=$(grep "Initial Root Token:" "$TOKEN_FILE" | awk '{print $NF}')
  fi
fi

if [ -z "$VAULT_TOKEN" ]; then
  echo "WARNING: No Vault token found — creating empty duo-credentials secret"
  kubectl create secret generic duo-credentials \
    -n infra \
    --from-literal=DUO_IKEY="" \
    --from-literal=DUO_SKEY="" \
    --from-literal=DUO_HOST="" \
    --dry-run=client -o yaml | kubectl apply -f -
  exit 0
fi

DUO_IKEY=$(kubectl exec -n infra vault-0 -- \
  sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault kv get -field=ikey secret/duo" 2>/dev/null || echo "")
DUO_SKEY=$(kubectl exec -n infra vault-0 -- \
  sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault kv get -field=skey secret/duo" 2>/dev/null || echo "")
DUO_HOST=$(kubectl exec -n infra vault-0 -- \
  sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault kv get -field=host secret/duo" 2>/dev/null || echo "")

if [ -z "$DUO_IKEY" ]; then
  echo "WARNING: Duo credentials not found in Vault — creating empty secret"
  echo "Run: vault kv put secret/duo ikey=<> skey=<> host=<>"
fi

kubectl create secret generic duo-credentials \
  -n infra \
  --from-literal=DUO_IKEY="${DUO_IKEY}" \
  --from-literal=DUO_SKEY="${DUO_SKEY}" \
  --from-literal=DUO_HOST="${DUO_HOST}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "duo-credentials secret synced to infra namespace"
