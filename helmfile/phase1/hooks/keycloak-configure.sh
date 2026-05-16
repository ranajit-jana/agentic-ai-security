#!/bin/bash
set -euo pipefail

echo "Waiting for Keycloak to be ready..."
kubectl wait pod -n infra -l app=keycloak --for=condition=Ready --timeout=300s

ADMIN_PASS=$(kubectl get secret keycloak-admin -n infra \
  -o jsonpath='{.data.password}' | base64 -d)

# Port-forward so curl can reach the ClusterIP service
kubectl port-forward svc/keycloak -n infra 18080:80 &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null || true" EXIT
sleep 5

KEYCLOAK_URL="http://localhost:18080"

# Get admin token
TOKEN=$(curl -sf -X POST \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=admin&password=${ADMIN_PASS}&grant_type=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

auth_header="Authorization: Bearer $TOKEN"

# Create firm-internal realm
curl -sf -X POST "$KEYCLOAK_URL/admin/realms" \
  -H "$auth_header" -H "Content-Type: application/json" \
  -d '{"realm":"firm-internal","enabled":true,"displayName":"Firm Internal"}' 2>/dev/null || true

# Enable CIBA on the realm
curl -sf -X PUT "$KEYCLOAK_URL/admin/realms/firm-internal" \
  -H "$auth_header" -H "Content-Type: application/json" \
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
  curl -sf -X POST "$KEYCLOAK_URL/admin/realms/firm-internal/roles" \
    -H "$auth_header" -H "Content-Type: application/json" \
    -d "{\"name\":\"$role\"}" 2>/dev/null || true
done

# Register CIBA ACP client
curl -sf -X POST "$KEYCLOAK_URL/admin/realms/firm-internal/clients" \
  -H "$auth_header" -H "Content-Type: application/json" \
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
