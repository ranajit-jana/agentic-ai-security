#!/bin/bash
set -euo pipefail

CONSUL_POD=$(kubectl get pod -n infra -l app=consul-server \
  -o jsonpath='{.items[0].metadata.name}')

echo "Writing test revocation to Consul..."
kubectl exec -n infra $CONSUL_POD -- \
  consul kv put agents/opal-sync-test '{"status":"revoked"}'

echo "Waiting up to 15s for OPA to reflect revocation..."
for i in $(seq 1 15); do
  RESULT=$(curl -sf -X POST \
    http://opa.infra.svc.cluster.local:8181/v1/data/agentic/baseline/allow \
    -H "Content-Type: application/json" \
    -d '{"input":{"agent_type":"opal-sync-test","tool":"web_search"}}' \
    | jq -r '.result' 2>/dev/null || echo "error")
  if [ "$RESULT" = "false" ]; then
    echo "OPAL sync verified — OPA reflects Consul state in ${i}s"
    kubectl exec -n infra $CONSUL_POD -- consul kv delete agents/opal-sync-test
    exit 0
  fi
  sleep 1
done

echo "ERROR: OPAL sync not confirmed after 15s"
exit 1
