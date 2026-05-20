#!/bin/bash
set -euo pipefail

kubectl wait pod -n infra consul-server-0 --for=condition=Ready --timeout=120s

CONSUL_TOKEN=$(kubectl get secret consul-bootstrap-acl-token -n infra \
  -o jsonpath='{.data.token}' | base64 -d)

echo "Writing test key to Consul..."
kubectl exec -n infra consul-server-0 -- \
  env CONSUL_HTTP_TOKEN="$CONSUL_TOKEN" consul kv put agents/opal-sync-test '{"status":"revoked"}'

OPAL_CLIENT_POD=$(kubectl get pod -n infra -l opal.ac/role=client \
  -o jsonpath='{.items[0].metadata.name}')

echo "Waiting up to 30s for OPAL to sync data to OPA..."
for i in $(seq 1 30); do
  RESULT=$(kubectl exec -n infra "$OPAL_CLIENT_POD" -- python3 -c "
import urllib.request, json
try:
    r = urllib.request.urlopen('http://opa.infra.svc.cluster.local:8282/v1/data/agents/opal-sync-test')
    d = json.loads(r.read())
    print('found' if d.get('result') else 'empty')
except:
    print('empty')
" 2>/dev/null || echo "empty")
  if [ "$RESULT" = "found" ]; then
    echo "OPAL sync verified — data appeared in OPA after ${i}s"
    kubectl exec -n infra consul-server-0 -- \
      env CONSUL_HTTP_TOKEN="$CONSUL_TOKEN" consul kv delete agents/opal-sync-test
    exit 0
  fi
  sleep 1
done

echo "ERROR: OPAL sync not confirmed after 30s"
kubectl exec -n infra consul-server-0 -- \
  env CONSUL_HTTP_TOKEN="$CONSUL_TOKEN" consul kv delete agents/opal-sync-test 2>/dev/null || true
exit 1
