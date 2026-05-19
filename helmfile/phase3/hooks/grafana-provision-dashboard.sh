#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../../../scripts/lib/common.sh"

log "Provisioning Security Posture dashboard into Grafana..."

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: posture-dashboard
  namespace: observability
  labels:
    grafana_dashboard: "1"
data:
  posture.json: |
    {
      "title": "Agentic AI Security Posture",
      "uid": "agentic-posture",
      "tags": ["security", "agentic-ai"],
      "panels": [
        {
          "title": "Active Agents",
          "type": "stat",
          "gridPos": {"x":0,"y":0,"w":4,"h":4},
          "targets": [{"expr": "count(consul_kv_get{key=~\"agents/.*\", status=\"active\"})"}]
        },
        {
          "title": "Policy Coverage %",
          "type": "gauge",
          "gridPos": {"x":4,"y":0,"w":4,"h":4},
          "fieldConfig": {"defaults": {"min":0,"max":100,"thresholds":{"steps":[
            {"value":0,"color":"red"},{"value":80,"color":"yellow"},{"value":95,"color":"green"}
          ]}}},
          "targets": [{"datasource":"OpenSearch","query":"gap_analysis.coverage_pct"}]
        },
        {
          "title": "Injection Attempts — 24h",
          "type": "timeseries",
          "gridPos": {"x":0,"y":4,"w":12,"h":6},
          "targets": [{"expr": "sum(rate(gateway_scan_unsafe_total[5m]))"}]
        },
        {
          "title": "OPA Deny Rate",
          "type": "timeseries",
          "gridPos": {"x":12,"y":4,"w":12,"h":6},
          "targets": [{"expr": "rate(opa_decision_deny_total[5m])"}]
        },
        {
          "title": "Biscuit Violations — 24h",
          "type": "stat",
          "gridPos": {"x":0,"y":10,"w":4,"h":4},
          "targets": [{"expr": "increase(gateway_biscuit_violation_total[24h])"}]
        },
        {
          "title": "HITL Triggers — 24h",
          "type": "stat",
          "gridPos": {"x":4,"y":10,"w":4,"h":4},
          "targets": [{"expr": "increase(ciba_approval_request_total[24h])"}]
        },
        {
          "title": "KubeArmor Blocks — 24h",
          "type": "stat",
          "gridPos": {"x":8,"y":10,"w":4,"h":4},
          "targets": [{"datasource":"OpenSearch","query":"kubearmor.action:Block AND @timestamp:[now-1d TO now]"}]
        },
        {
          "title": "GuardDuty Findings",
          "type": "table",
          "gridPos": {"x":0,"y":14,"w":24,"h":6},
          "targets": [{"datasource":"OpenSearch","query":"source:aws.guardduty"}]
        },
        {
          "title": "Cedar Policy Rejections",
          "type": "timeseries",
          "gridPos": {"x":0,"y":20,"w":12,"h":6},
          "targets": [{"expr": "rate(cedar_policy_deny_total[5m])"}]
        },
        {
          "title": "Tool Hash Mismatches",
          "type": "stat",
          "gridPos": {"x":12,"y":20,"w":4,"h":4},
          "targets": [{"expr": "sum(consul_kv_get{key=~\"tools/.*\", status=\"hash_mismatch\"})"}]
        },
        {
          "title": "Correlation Rule Alerts",
          "type": "table",
          "gridPos": {"x":0,"y":24,"w":24,"h":6},
          "targets": [{"datasource":"OpenSearch","query":"_index:opensearch-alerting-alert*"}]
        }
      ]
    }
EOF

kubectl rollout restart deployment grafana -n observability
kubectl rollout status deployment grafana -n observability

log "Security Posture dashboard provisioned"
