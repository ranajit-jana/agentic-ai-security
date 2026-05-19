#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../../../scripts/lib/common.sh"
load_env

OS_ADMIN_PASS=$(kubectl exec -n infra vault-0 -- \
  vault kv get -field=admin_password secret/opensearch 2>/dev/null || \
  kubectl get secret opensearch-credentials -n observability \
    -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d)

kubectl create secret generic opensearch-credentials \
  -n observability \
  --from-literal=admin_password="$OS_ADMIN_PASS" \
  --from-literal=OPENSEARCH_ADMIN_PASSWORD="$OS_ADMIN_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

OS_URL="https://opensearch-cluster-master.observability.svc.cluster.local:9200"
AUTH="-u admin:${OS_ADMIN_PASS} -sk"

log "Waiting for OpenSearch cluster to be green..."
for i in $(seq 1 30); do
  STATUS=$(curl $AUTH "${OS_URL}/_cluster/health" \
    | jq -r '.status' 2>/dev/null || echo "red")
  [ "$STATUS" = "green" ] && { log "OpenSearch is green"; break; }
  log "  [$i/30] status=$STATUS — retrying in 10s..."
  sleep 10
done
[ "$STATUS" = "green" ] || { log "ERROR: OpenSearch did not reach green"; exit 1; }

# ── ISM policy: auto-delete indices older than 1 day ──────────────────────
log "Loading index lifecycle (ISM) policy — delete after 1 day..."
curl $AUTH -X PUT "${OS_URL}/_plugins/_ism/policies/daily-rollover" \
  -H "Content-Type: application/json" \
  -d '{
    "policy": {
      "description": "Delete indices older than 1 day — data is re-generated on each rebuild",
      "default_state": "live",
      "states": [
        {
          "name": "live",
          "actions": [],
          "transitions": [
            {
              "state_name": "delete",
              "conditions": { "min_index_age": "1d" }
            }
          ]
        },
        {
          "name": "delete",
          "actions": [{ "delete": {} }],
          "transitions": []
        }
      ],
      "ism_template": [
        { "index_patterns": ["kubearmor-*", "agentic-audit-*", "guardduty-*"] }
      ]
    }
  }'
log "ISM policy loaded"

# ── Correlation rules ──────────────────────────────────────────────────────
log "Loading Security Analytics correlation rules..."
BASE_URL="${OS_URL}/_plugins/_security_analytics/rules"

log "  Rule 1: Injection then tool call within 60s (same agent)"
curl $AUTH -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Injection then tool call",
    "log_source": {"product": "agentic-gateway"},
    "description": "Prompt injection detected followed by a tool call within 60s from the same agent_id",
    "detection": {
      "timeframe": 60,
      "condition": "injection_event and tool_call_event",
      "injection_event": {"scan_result": "unsafe"},
      "tool_call_event": {"event_type": "tool_call"}
    },
    "severity": "critical"
  }'

log "  Rule 2: Biscuit scope violation"
curl $AUTH -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Biscuit scope violation",
    "log_source": {"product": "agentic-gateway"},
    "description": "Agent attempted a tool call outside its Biscuit token scope",
    "detection": {
      "condition": "biscuit_violation",
      "biscuit_violation": {"verified": false, "reason": "scope_exceeded"}
    },
    "severity": "high"
  }'

log "  Rule 3: KubeArmor block + GuardDuty finding on same node within 5 min"
curl $AUTH -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Runtime anomaly cluster",
    "log_source": {"product": "kubearmor"},
    "description": "KubeArmor block and GuardDuty finding on the same node within 5 minutes",
    "detection": {
      "timeframe": 300,
      "condition": "kubearmor_block and guardduty_finding",
      "kubearmor_block": {"action": "Block"},
      "guardduty_finding": {"source": "aws.guardduty"}
    },
    "severity": "critical"
  }'

log "Correlation rules loaded — OpenSearch ready"
