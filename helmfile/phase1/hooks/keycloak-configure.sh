#!/bin/bash
set -euo pipefail

echo "Waiting for Keycloak to be ready..."
kubectl wait pod -n infra -l app=keycloak --for=condition=Ready --timeout=300s

ADMIN_PASS=$(kubectl get secret keycloak-admin -n infra \
  -o jsonpath='{.data.password}' | base64 -d)

KEYCLOAK_URL="http://keycloak.infra.svc.cluster.local"

# Get admin token from inside the cluster via ciba-acp pod
TOKEN=$(kubectl exec -n infra deploy/ciba-acp -- \
  curl -sf --max-time 10 -X POST \
  "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=admin&password=${ADMIN_PASS}&grant_type=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Create firm-internal realm
kubectl exec -n infra deploy/ciba-acp -- \
  curl -sf --max-time 10 -X POST "${KEYCLOAK_URL}/admin/realms" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"realm":"firm-internal","enabled":true,"displayName":"Firm Internal"}' 2>/dev/null || true

# Enable CIBA on the realm
kubectl exec -n infra deploy/ciba-acp -- \
  curl -sf --max-time 10 -X PUT "${KEYCLOAK_URL}/admin/realms/firm-internal" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "attributes": {
      "cibaBackchannelTokenDeliveryMode": "poll",
      "cibaExpiresIn": "120",
      "cibaInterval": "5",
      "cibaAuthRequestedUserHint": "login_hint"
    }
  }'

# Create realm roles
for role in analyst admin viewer; do
  kubectl exec -n infra deploy/ciba-acp -- \
    curl -sf --max-time 10 -X POST \
    "${KEYCLOAK_URL}/admin/realms/firm-internal/roles" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$role\"}" 2>/dev/null || true
done

# Register CIBA ACP client
kubectl exec -n infra deploy/ciba-acp -- \
  curl -sf --max-time 10 -X POST \
  "${KEYCLOAK_URL}/admin/realms/firm-internal/clients" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "ciba-acp",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "redirectUris": ["https://acp.firm.internal/*"],
    "attributes": {
      "backchannel.logout.session.required": "true"
    }
  }' 2>/dev/null || true

echo "Keycloak realm firm-internal with CIBA configured"
