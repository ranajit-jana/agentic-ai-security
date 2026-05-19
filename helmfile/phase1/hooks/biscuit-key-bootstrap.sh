#!/bin/bash
set -euo pipefail

for agent in orchestrator-agent web-search-agent internal-data-agent \
             report-generation-agent email-agent; do
  SVID_KEY=$(kubectl exec -n agents deploy/$agent -- \
    /opt/spire/bin/spire-agent api fetch x509 -write /tmp/svid \
    2>/dev/null && cat /tmp/svid/svid.0.key | base64 -w0)

  kubectl create secret generic biscuit-key-$agent \
    -n infra \
    --from-literal=private_key=$SVID_KEY \
    --dry-run=client -o yaml | kubectl apply -f -
done

kubectl rollout restart deployment/security-gateway -n infra
kubectl rollout status deployment/security-gateway -n infra

echo "Biscuit signing keys registered — SVID keys active"
