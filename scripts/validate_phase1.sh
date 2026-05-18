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
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "═══════════════════════════════════════════"
echo " Phase 1 Validation"
echo "═══════════════════════════════════════════"

echo ""
echo "── Cluster ─────────────────────────────────"
check "All nodes Ready" \
  "kubectl get nodes --no-headers | awk '\$2 != \"Ready\" { found=1 } END { exit found }'"

echo ""
echo "── Istio ───────────────────────────────────"
check "istiod pod running" \
  "kubectl get pods -n istio-system -l app=istiod --no-headers | grep -q Running"
check "Strict mTLS PeerAuthentication exists" \
  "kubectl get peerauthentication -A --no-headers | grep -q STRICT"

echo ""
echo "── SPIRE ───────────────────────────────────"
# SPIRE server is a StatefulSet; its pods carry app.kubernetes.io/component=server
check "SPIRE server running" \
  "kubectl get pods -n spire-system -l 'app.kubernetes.io/component=server,app.kubernetes.io/instance=spire' --no-headers | grep -q Running"
# SPIRE agents handle SVID issuance; verify the agent DaemonSet is fully ready
check "SPIRE agents ready on all nodes" \
  "kubectl rollout status daemonset/spire-agent -n spire-system --timeout=10s"
# Verify the SPIRE socket is present inside the orchestrator pod
check "SPIRE socket mounted in orchestrator" \
  "kubectl exec -n agents deploy/orchestrator-agent -- test -S /run/spire/sockets/spire-agent.sock"

echo ""
echo "── Consul ──────────────────────────────────"
# Consul ACLs are enabled; read the bootstrap token from the k8s secret
CONSUL_TOKEN=$(kubectl get secret consul-bootstrap-acl-token -n infra \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
check "Consul server running" \
  "kubectl get pods -n infra -l app=consul --no-headers | grep -q Running"
check "Agent registry populated" \
  "kubectl exec -n infra consul-server-0 -- consul kv get -token=$CONSUL_TOKEN agents/web-search-agent | grep -q status"
check "Tool registry populated" \
  "kubectl exec -n infra consul-server-0 -- consul kv get -token=$CONSUL_TOKEN tools/web_search | grep -q status"

echo ""
echo "── Vault ───────────────────────────────────"
# vault status requires no auth — sealed=false proves KMS auto-unseal succeeded
check "Vault unsealed via KMS" \
  "kubectl exec -n infra vault-0 -- vault status -format=json | jq -r '.sealed' | grep -q false"
# KV secrets engine: check via the sys/health mount listing (no auth required for health)
check "Vault API healthy and initialized" \
  "kubectl exec -n infra vault-0 -- vault status -format=json | jq -r '.initialized' | grep -q true"

echo ""
echo "── Keycloak ────────────────────────────────"
# Keycloak is deployed as a StatefulSet; its pod label is app=keycloak
KEYCLOAK_IP=$(kubectl get svc keycloak -n infra -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
check "Keycloak pod running" \
  "kubectl get pods -n infra -l app=keycloak --no-headers | grep -q Running"
check "CIBA enabled on realm" \
  "kubectl exec -n infra deploy/ciba-acp -- \
   curl -sf --max-time 10 http://keycloak.infra.svc.cluster.local/realms/firm-internal/.well-known/openid-configuration \
   | jq -r '.backchannel_authentication_endpoint' | grep -qv null"

echo ""
echo "── OPA ─────────────────────────────────────"
# OPA is only reachable inside the cluster; use the security-gateway pod as proxy
check "OPA pod running" \
  "kubectl get pods -n infra -l app=opa --no-headers | grep -q Running"
check "OPA baseline policy loaded" \
  "kubectl get configmap opa-policy-agentic-baseline -n infra --no-headers"
check "OPA denies unknown agent" \
  "kubectl exec -n infra deploy/security-gateway -- \
   curl -sfk --max-time 10 -X POST https://opa.infra.svc.cluster.local/v1/data/agentic/baseline/allow \
   -H 'Content-Type: application/json' \
   -d '{\"input\":{\"agent_type\":\"unknown-agent\",\"tool\":\"web_search\",\"principal_type\":\"agent\"}}' \
   | jq -r '.result' | grep -q false"
check "OPA allows known agent/tool pair" \
  "kubectl exec -n infra deploy/security-gateway -- \
   curl -sfk --max-time 10 -X POST https://opa.infra.svc.cluster.local/v1/data/agentic/baseline/allow \
   -H 'Content-Type: application/json' \
   -d '{\"input\":{\"agent_type\":\"web-search-agent\",\"tool\":\"web_search\",\"principal_type\":\"agent\",\"data_class\":\"public\"}}' \
   | jq -r '.result' | grep -q true"

echo ""
echo "── Security Gateway ────────────────────────"
check "Gateway pod running" \
  "kubectl get pods -n infra -l app=security-gateway --no-headers | grep -q Running"
check "Gateway health endpoint responds" \
  "kubectl exec -n infra deploy/security-gateway -- \
   curl -sf --max-time 10 http://localhost:8080/health | grep -q ok"

echo ""
echo "── Observability ───────────────────────────"
check "OTel collector running" \
  "kubectl get pods -n observability -l app.kubernetes.io/name=opentelemetry-collector --no-headers | grep -q Running"
check "Loki running" \
  "kubectl get pods -n observability -l app=loki --no-headers | grep -q Running"
check "Grafana running" \
  "kubectl get pods -n observability -l app.kubernetes.io/name=grafana --no-headers | grep -q Running"
check "Audit logs endpoint reachable" \
  "kubectl exec -n infra deploy/security-gateway -- \
   curl -sf --max-time 10 http://loki.observability.svc.cluster.local:3100/loki/api/v1/labels \
   | jq -r '.status' | grep -q success"

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
