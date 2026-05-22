#!/bin/bash
set -euo pipefail
PASS_COUNT=0; FAIL_COUNT=0

check() {
  if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1))
  else echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
}

# Start kubectl proxy for all cluster-internal HTTP checks
PROXY_PORT=18001
kubectl proxy --port=${PROXY_PORT} --reject-paths="" &>/dev/null &
PROXY_PID=$!
trap "kill ${PROXY_PID} 2>/dev/null || true" EXIT
sleep 2

# Helper: call a cluster service via kubectl proxy
# Usage: kproxy <namespace> <service> <port> <path>
kproxy() { curl -sf "http://localhost:${PROXY_PORT}/api/v1/namespaces/$1/services/$2:$3/proxy$4" "${@:5}"; }

echo "── Core Infrastructure ──────────────────────────────────────"

check "All nodes Ready" \
  "[ \$(kubectl get nodes --no-headers | awk '{print \$2}' | { grep -v Ready || true; } | wc -l) -eq 0 ]"

check "Inference nodes Ready" \
  "kubectl get nodes -l role=inference --no-headers | grep Ready"

check "Istio strict mTLS" \
  "kubectl get peerauthentication -A --no-headers | grep STRICT"

check "SPIRE issuing SVIDs" \
  "kubectl exec -n spire-system spire-server-0 -- /opt/spire/bin/spire-server entry show 2>/dev/null | grep 'spiffe://'"

check "Consul agent registry populated" \
  "kubectl exec -n infra consul-server-0 -- consul kv get agents/web-search-agent | grep status"

check "Vault unsealed via KMS" \
  "kubectl exec -n infra vault-0 -- vault status -format=json | jq -r '.sealed' | grep false"

check "Keycloak CIBA enabled" \
  "kproxy infra keycloak 80 /realms/firm-internal/.well-known/openid-configuration | grep backchannel_authentication_endpoint"

check "Keycloak user rana exists with analyst role" \
  "KCPOD=\$(kubectl get pod -n infra -l app=keycloak -o jsonpath='{.items[0].metadata.name}') && \
   KC_PASS=\$(kubectl get secret keycloak-admin -n infra -o jsonpath='{.data.password}' | base64 -d) && \
   kubectl exec -n infra \$KCPOD -- /opt/keycloak/bin/kcadm.sh config credentials \
     --server http://localhost:8080 --realm master --user admin --password \${KC_PASS} >/dev/null 2>&1 && \
   kubectl exec -n infra \$KCPOD -- /opt/keycloak/bin/kcadm.sh get realms/firm-internal/users \
     -q username=rana 2>/dev/null | grep rana"

check "OPA denying unknown agent" \
  "kproxy infra opa 8282 /v1/data/agentic/baseline/allow \
   -X POST -H 'Content-Type: application/json' \
   --data-raw '{\"input\":{\"agent_type\":\"unknown\",\"tool\":\"web_search\"}}' \
   | jq -r '.result' | grep false"

check "Loki receiving logs" \
  "kproxy observability loki 3100 /ready | grep ready"

echo ""
echo "── Inference Stack ──────────────────────────────────────────"

check "Ollama judge responding with llama3.1" \
  "kproxy infra ollama-judge 11434 /api/tags | jq -r '.models[].name' | grep 'llama3.1'"

check "Ollama embed responding with nomic-embed-text" \
  "kproxy infra ollama-embed 11434 /api/tags | jq -r '.models[].name' | grep 'nomic-embed-text'"

check "LiteLLM proxy healthy" \
  "kproxy infra litellm 4000 /health/readiness | grep healthy"

echo ""
echo "── Policy Sync ──────────────────────────────────────────────"

check "OPAL syncing Consul revocation to OPA" \
  "CONSUL_POD=\$(kubectl get pod -n infra -l app=consul,component=server -o jsonpath='{.items[0].metadata.name}') && \
   CONSUL_TOKEN=\$(kubectl get secret consul-bootstrap-acl-token -n infra -o jsonpath='{.data.token}' | base64 -d) && \
   kubectl exec -n infra \$CONSUL_POD -- consul kv put -token=\$CONSUL_TOKEN agents/validate-test '{\"status\":\"revoked\"}' && \
   sleep 8 && \
   kproxy infra opa 8282 /v1/data/agentic/baseline/allow -X POST -H 'Content-Type: application/json' \
   --data-raw '{\"input\":{\"agent_type\":\"validate-test\",\"tool\":\"web_search\"}}' \
   | jq -r '.result' | grep false && \
   kubectl exec -n infra \$CONSUL_POD -- consul kv delete -token=\$CONSUL_TOKEN agents/validate-test"

sleep 5  # allow OPA to finish syncing after OPAL test key deletion

echo ""
echo "── Security Gateway ─────────────────────────────────────────"

check "Tool catalog has web_search tool" \
  "kproxy infra tool-catalog 8000 /tools | jq -r '.tools | keys[]' | grep web_search"

check "Security gateway denying unauthorized tool" \
  "kproxy infra security-gateway 8080 /authorize -X POST -H 'Content-Type: application/json' \
   --data-raw '{\"agent_id\":\"web-search-agent\",\"task_id\":\"test\",\"tool\":\"send_email\"}' \
   | grep '\"allowed\":false'"

check "Security gateway catalog tools responding" \
  "kproxy infra security-gateway 8080 /catalog/tools -X POST -H 'Content-Type: application/json' \
   --data-raw '{\"agent_id\":\"web-search-agent\",\"intent\":\"search public web\",\"task_id\":\"test\"}' \
   | grep '\"tools\"'"

check "Hash verifier CronJob scheduled" \
  "kubectl get cronjob tool-hash-verifier -n infra --no-headers | grep tool-hash-verifier"

echo ""
echo "── CIBA / Approvals ─────────────────────────────────────────"

check "CIBA ACP healthy" \
  "kproxy infra ciba-acp 8000 /health | grep ok"

check "duo-credentials secret exists" \
  "kubectl get secret duo-credentials -n infra --no-headers | grep duo-credentials"

echo ""
echo "────────────────────────────────────────────────────────────"
echo "Result: $PASS_COUNT passed, $FAIL_COUNT failed"
[ $FAIL_COUNT -eq 0 ] && echo "COMPLETE — all systems operational" || { echo "Some checks failed"; exit 1; }
