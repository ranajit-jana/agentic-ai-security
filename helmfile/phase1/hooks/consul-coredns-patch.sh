#!/bin/bash
set -euo pipefail

CONSUL_DNS="$(kubectl get svc -n infra consul-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || \
              kubectl get svc -n infra consul-server -o jsonpath='{.spec.clusterIP}')"

# Patch CoreDNS to forward *.consul queries to Consul DNS
kubectl get configmap coredns -n kube-system -o json | \
  python3 -c "
import json, sys
cm = json.load(sys.stdin)
corefile = cm['data']['Corefile']
stub = '''
consul {
    errors
    cache 10
    forward . CONSUL_IP:8600
}
'''.replace('CONSUL_IP', '$CONSUL_DNS')
if 'consul {' not in corefile:
    corefile = corefile.rstrip() + '\n' + stub
    cm['data']['Corefile'] = corefile
print(json.dumps(cm))
" | kubectl apply -f -

kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=60s

echo "CoreDNS patched for Consul DNS forwarding (*.consul → $CONSUL_DNS:8600)"
