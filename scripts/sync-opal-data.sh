#!/bin/bash
# Triggers a full OPAL data sync (Consul KV → OPA) and verifies it landed.
set -euo pipefail

NAMESPACE=infra
TIMEOUT=${1:-60}

# ── Pods ──────────────────────────────────────────────────────────────────────

OPAL_SERVER_POD=$(kubectl get pod -n "$NAMESPACE" -l opal.ac/role=server \
  -o jsonpath='{.items[0].metadata.name}')
OPAL_CLIENT_POD=$(kubectl get pod -n "$NAMESPACE" -l opal.ac/role=client \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')

echo "OPAL server : $OPAL_SERVER_POD"
echo "OPAL client : $OPAL_CLIENT_POD"

# ── Trigger full data refresh via OPAL server API ─────────────────────────────

echo ""
echo "Triggering data refresh on OPAL server..."
kubectl exec -n "$NAMESPACE" "$OPAL_SERVER_POD" -- python3 -c "
import urllib.request, json

payload = json.dumps({
    'entries': [
        {
            'url': 'http://consul-server.infra.svc.cluster.local:8500/v1/kv/agents?recurse=true',
            'topics': ['agents'],
            'dst_path': '/agents'
        },
        {
            'url': 'http://consul-server.infra.svc.cluster.local:8500/v1/kv/tools?recurse=true',
            'topics': ['tools'],
            'dst_path': '/tools'
        }
    ],
    'reason': 'manual sync'
}).encode()

req = urllib.request.Request(
    'http://localhost:7002/data/update',
    data=payload,
    headers={'Content-Type': 'application/json'},
    method='POST'
)
try:
    r = urllib.request.urlopen(req, timeout=10)
    print('Refresh triggered, status:', r.status)
except Exception as e:
    print('ERROR triggering refresh:', e)
    exit(1)
"

# ── Wait for data to appear in OPA ────────────────────────────────────────────

echo ""
echo "Waiting up to ${TIMEOUT}s for data to appear in OPA..."
for i in $(seq 1 "$TIMEOUT"); do
  RESULT=$(kubectl exec -n "$NAMESPACE" "$OPAL_CLIENT_POD" -- python3 -c "
import urllib.request, json
try:
    r = urllib.request.urlopen('http://opa.infra.svc.cluster.local:8282/v1/data/agents', timeout=5)
    d = json.loads(r.read())
    agents = d.get('result', {})
    print(len(agents))
except Exception as e:
    print(0)
" 2>/dev/null || echo 0)

  if [ "${RESULT:-0}" -gt 0 ] 2>/dev/null; then
    echo "✓ Data synced — $RESULT agent entries found in OPA after ${i}s"
    break
  fi

  if [ "$i" -eq "$TIMEOUT" ]; then
    echo "ERROR: Data did not appear in OPA after ${TIMEOUT}s"
    echo ""
    echo "OPAL client logs (last 20 lines):"
    kubectl logs -n "$NAMESPACE" "$OPAL_CLIENT_POD" --tail=20 2>/dev/null | grep -v healthcheck
    exit 1
  fi
  printf "."
  sleep 1
done

# ── Verify tools too ──────────────────────────────────────────────────────────

echo ""
echo "Verifying tools data..."
TOOL_COUNT=$(kubectl exec -n "$NAMESPACE" "$OPAL_CLIENT_POD" -- python3 -c "
import urllib.request, json
try:
    r = urllib.request.urlopen('http://opa.infra.svc.cluster.local:8282/v1/data/tools', timeout=5)
    d = json.loads(r.read())
    print(len(d.get('result', {})))
except:
    print(0)
" 2>/dev/null || echo 0)

echo "✓ $TOOL_COUNT tool entries in OPA"
echo ""
echo "OPAL data sync complete."
