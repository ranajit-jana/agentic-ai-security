#!/bin/bash
set -euo pipefail
source scripts/lib/common.sh

log "Verifying Phase 1 complete..."
./scripts/validate_phase1.sh || {
  echo "ERROR: Phase 1 validation failed. Complete Phase 1 first."
  exit 1
}

log "Verifying Duo credentials in Vault..."
kubectl exec -n infra vault-0 -- \
  vault kv get secret/duo >/dev/null 2>&1 || {
  echo "ERROR: Duo credentials not found in Vault."
  echo "Run: vault kv put secret/duo ikey=<ikey> skey=<skey> host=<host>"
  exit 1
}

log "Phase 2 prerequisites satisfied"
