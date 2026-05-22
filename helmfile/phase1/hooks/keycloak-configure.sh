#!/bin/bash
set -euo pipefail

echo "Waiting for Keycloak to be ready..."
kubectl wait pod -n infra -l app=keycloak --for=condition=Ready --timeout=300s

ADMIN_PASS=$(kubectl get secret keycloak-admin -n infra \
  -o jsonpath='{.data.password}' | base64 -d)

KCADM="kubectl exec -n infra statefulset/keycloak -- /opt/keycloak/bin/kcadm.sh"

# Authenticate — retry until admin API is up (pod ready != API ready)
for i in $(seq 1 12); do
  $KCADM config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user admin \
    --password "${ADMIN_PASS}" 2>/dev/null && break
  echo "Keycloak admin API not ready yet, retrying ($i/12)..."
  sleep 10
done

# Create firm-internal realm
$KCADM create realms \
  -s realm=firm-internal \
  -s enabled=true \
  -s displayName="Firm Internal" 2>/dev/null || true

# Enable CIBA on the realm
$KCADM update realms/firm-internal \
  -s "attributes.cibaBackchannelTokenDeliveryMode=poll" \
  -s "attributes.cibaExpiresIn=120" \
  -s "attributes.cibaInterval=5" \
  -s "attributes.cibaAuthRequestedUserHint=login_hint" 2>/dev/null || true

# Create realm roles
for role in analyst admin viewer; do
  $KCADM create realms/firm-internal/roles -s name="${role}" 2>/dev/null || true
done

# Register CIBA ACP client
$KCADM create realms/firm-internal/clients \
  -s clientId=ciba-acp \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s 'redirectUris=["https://acp.firm.internal/*"]' \
  -s 'attributes.backchannel.logout.session.required=true' 2>/dev/null || true

# Create user rana with analyst role
$KCADM create realms/firm-internal/users \
  -s username=rana \
  -s enabled=true \
  -s 'credentials=[{"type":"password","value":"changeme123","temporary":false}]' 2>/dev/null || true

RANA_ID=$($KCADM get realms/firm-internal/users -q username=rana \
  --fields id 2>/dev/null | python3 -c "import sys,json; data=json.load(sys.stdin); print(data[0]['id'])" 2>/dev/null || echo "")

ANALYST_ID=$($KCADM get realms/firm-internal/roles/analyst \
  --fields id 2>/dev/null | python3 -c "import sys,json; data=json.load(sys.stdin); print(data['id'])" 2>/dev/null || echo "")

if [ -n "$RANA_ID" ] && [ -n "$ANALYST_ID" ]; then
  $KCADM create realms/firm-internal/users/$RANA_ID/role-mappings/realm \
    -r firm-internal \
    -s "[{\"id\":\"${ANALYST_ID}\",\"name\":\"analyst\"}]" 2>/dev/null || true
  echo "User rana created with analyst role"
fi

echo "Keycloak realm firm-internal with CIBA configured"
