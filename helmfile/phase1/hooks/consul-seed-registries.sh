#!/bin/bash
set -euo pipefail

echo "Waiting for Consul server pod to be ready..."
kubectl wait pod consul-server-0 -n infra \
  --for=condition=Ready --timeout=180s

CONSUL_POD="consul-server-0"

CONSUL_TOKEN=$(kubectl get secret consul-bootstrap-acl-token -n infra \
  -o jsonpath='{.data.token}' | base64 -d)

kv_put() {
  kubectl exec -n infra "$CONSUL_POD" -- \
    env CONSUL_HTTP_TOKEN="$CONSUL_TOKEN" consul kv put "$1" "$2"
}

# Agent registry
kv_put agents/orchestrator-agent \
  '{"role":"agent-orchestrator","allowed_tools":["web_search","query_internal_db","generate_report","send_email"],"max_data_classification":"confidential","status":"active"}'

kv_put agents/web-search-agent \
  '{"role":"agent-researcher-public","allowed_tools":["web_search"],"max_data_classification":"public","status":"active"}'

kv_put agents/internal-data-agent \
  '{"role":"agent-researcher-internal","allowed_tools":["query_internal_db"],"max_data_classification":"confidential","status":"active"}'

kv_put agents/report-generation-agent \
  '{"role":"agent-writer","allowed_tools":["generate_report"],"max_data_classification":"confidential","status":"active"}'

kv_put agents/email-agent \
  '{"role":"agent-communicator","allowed_tools":["send_email"],"max_data_classification":"confidential","status":"active"}'

# Tool registry
kv_put tools/web_search \
  '{"mcp_endpoint":"https://web-search.tools.svc.cluster.local","allowed_callers":["web-search-agent","orchestrator-agent"],"data_classification":"public","blast_radius":"low","status":"active"}'

kv_put tools/query_internal_db \
  '{"mcp_endpoint":"https://internal-db.tools.svc.cluster.local","allowed_callers":["internal-data-agent","orchestrator-agent"],"data_classification":"confidential","blast_radius":"medium","status":"active"}'

kv_put tools/generate_report \
  '{"mcp_endpoint":"https://report-gen.tools.svc.cluster.local","allowed_callers":["report-generation-agent","orchestrator-agent"],"data_classification":"confidential","blast_radius":"low","status":"active"}'

kv_put tools/send_email \
  '{"mcp_endpoint":"https://email.tools.svc.cluster.local","allowed_callers":["email-agent","orchestrator-agent"],"data_classification":"confidential","blast_radius":"high","status":"active"}'

echo "Consul agent and tool registries seeded"
