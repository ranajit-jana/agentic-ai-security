#!/bin/bash
# Phase 1 validation — runs automated checks against a live cluster
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

PASS=0
FAIL=0

check() {
  local label="$1"
  shift
  if eval "$*" >/dev/null 2>&1; then
    echo "  PASS: $label"
    ((PASS++))
  else
    echo "  FAIL: $label"
    ((FAIL++))
  fi
}

echo ""
echo "═══════════════════════════════════════════"
echo " Phase 1 Validation"
echo "═══════════════════════════════════════════"

echo ""
echo "── Cluster ─────────────────────────────────"
check "All nodes Ready" \
  "kubectl get nodes --no-headers | awk '{print \$2}' | grep -v '^Ready$' | wc -l | grep -q '^0$'"

echo ""
echo "── Istio ───────────────────────────────────"
check "istiod pod running" \
  "kubectl get pods -n istio-system -l app=istiod --no-headers | grep -q Running"
check "Strict mTLS PeerAuthentication exists" \
  "kubectl get peerauthentication -A --no-headers | grep -q STRICT"

echo ""
echo "── SPIRE ───────────────────────────────────"
check "SPIRE server running" \
  "kubectl get pods -n spire-system -l app=spire-server --no-headers | grep -q Running"
check "Orchestrator agent receives SVID" \
  "kubectl exec -n agents deploy/orchestrator-agent -- \
   /opt/spire/bin/spire-agent api fetch x509 2>&1 | grep -q 'spiffe://'"

echo ""
echo "── Consul ──────────────────────────────────"
check "Consul server running" \
  "kubectl get pods -n infra -l app=consul --no-headers | grep -q Running"
check "Agent registry populated" \
  "kubectl exec -n infra consul-server-0 -- consul kv get agents/web-search-agent | grep -q status"
check "Tool registry populated" \
  "kubectl exec -n infra consul-server-0 -- consul kv get tools/web_search | grep -q status"

echo ""
echo "── Vault ───────────────────────────────────"
check "Vault unsealed via KMS" \
  "kubectl exec -n infra vault-0 -- vault status -format=json | jq -r '.sealed' | grep -q false"
check "KV secrets engine enabled" \
  "kubectl exec -n infra vault-0 -- vault secrets list | grep -q secret/"

echo ""
echo "── Keycloak ────────────────────────────────"
KEYCLOAK_IP=$(kubectl get svc keycloak -n infra -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
check "Keycloak pod running" \
  "kubectl get pods -n infra -l app.kubernetes.io/name=keycloak --no-headers | grep -q Running"
check "CIBA enabled on realm" \
  "curl -sf http://${KEYCLOAK_IP}/realms/firm-internal \
   | jq -r '.attributes.cibaBackchannelTokenDeliveryMode' | grep -q poll"

echo ""
echo "── OPA ─────────────────────────────────────"
OPA_IP=$(kubectl get svc opa -n infra -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
check "OPA pod running" \
  "kubectl get pods -n infra -l app=opa --no-headers | grep -q Running"
check "OPA denies unknown agent" \
  "curl -sf -X POST http://${OPA_IP}:8181/v1/data/agentic/baseline/allow \
   -H 'Content-Type: application/json' \
   -d '{\"input\":{\"agent_type\":\"unknown-agent\",\"tool\":\"web_search\",\"principal_type\":\"agent\"}}' \
   | jq -r '.result' | grep -q false"
check "OPA allows known agent/tool pair" \
  "curl -sf -X POST http://${OPA_IP}:8181/v1/data/agentic/baseline/allow \
   -H 'Content-Type: application/json' \
   -d '{\"input\":{\"agent_type\":\"web-search-agent\",\"tool\":\"web_search\",\"principal_type\":\"agent\",\"data_class\":\"public\"}}' \
   | jq -r '.result' | grep -q true"

echo ""
echo "── Security Gateway ────────────────────────"
check "Gateway pod running" \
  "kubectl get pods -n infra -l app=security-gateway --no-headers | grep -q Running"
check "Gateway health endpoint responds" \
  "kubectl exec -n infra deploy/security-gateway -- \
   curl -sf http://localhost:8080/health | grep -q ok"

echo ""
echo "── Observability ───────────────────────────"
check "OTel collector running" \
  "kubectl get pods -n observability -l app.kubernetes.io/name=opentelemetry-collector --no-headers | grep -q Running"
check "Loki running" \
  "kubectl get pods -n observability -l app=loki --no-headers | grep -q Running"
check "Grafana running" \
  "kubectl get pods -n observability -l app.kubernetes.io/name=grafana --no-headers | grep -q Running"
check "Audit logs flowing to Loki" \
  "LOKI_IP=\$(kubectl get svc loki -n observability -o jsonpath='{.spec.clusterIP}'); \
   curl -sf \"http://\${LOKI_IP}:3100/loki/api/v1/labels\" | jq -r '.data[]' | grep -q agent_id"

echo ""
echo "═══════════════════════════════════════════"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "═══════════════════════════════════════════"
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo "Phase 1 COMPLETE — proceed to Phase 2"
  exit 0
else
  echo "Phase 1 INCOMPLETE — fix failures before proceeding"
  exit 1
fi
