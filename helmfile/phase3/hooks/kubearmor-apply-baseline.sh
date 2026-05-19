#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../../../scripts/lib/common.sh"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

log "Installing karmor CLI..."
curl -sfL https://raw.githubusercontent.com/kubearmor/KubeArmor/main/pkg/KubeArmor/karmor/install.sh \
  | sudo bash

log "Applying reviewed baseline policies..."
POLICY_FILE="${REPO_ROOT}/policies/kubearmor-baseline.yaml"
[ -f "$POLICY_FILE" ] || {
  log "ERROR: $POLICY_FILE not found — complete MANUAL STEP 7 (karmor discover + review)"
  exit 1
}
kubectl apply -f "$POLICY_FILE"

COUNT=$(kubectl get kubearmorpolicies -A --no-headers 2>/dev/null | wc -l)
log "KubeArmor policies applied: $COUNT"
[ "$COUNT" -gt 0 ] || { log "ERROR: No KubeArmor policies found after apply"; exit 1; }

log "KubeArmor baseline policies active"
