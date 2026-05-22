#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../../../scripts/lib/common.sh"

log "Provisioning Security Posture dashboard into Grafana via operator CRD..."

kubectl apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: agentic-posture
  namespace: observability
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folder: "Security Posture"
  json: |
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
          "datasource": {"type": "grafana-clickhouse-datasource", "uid": "clickhouse"},
          "targets": [{"rawSql": "SELECT coverage_pct FROM security.gap_analysis ORDER BY ts DESC LIMIT 1"}]
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
          "datasource": {"type": "grafana-clickhouse-datasource", "uid": "clickhouse"},
          "targets": [{"rawSql": "SELECT count() FROM security.kubearmor_events WHERE action='Block' AND ts >= now() - INTERVAL 1 DAY"}]
        },
        {
          "title": "GuardDuty Findings",
          "type": "table",
          "gridPos": {"x":0,"y":14,"w":24,"h":6},
          "datasource": {"type": "grafana-clickhouse-datasource", "uid": "clickhouse"},
          "targets": [{"rawSql": "SELECT ts, severity, title, region FROM security.guardduty_findings ORDER BY ts DESC LIMIT 100"}]
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
          "datasource": {"type": "grafana-clickhouse-datasource", "uid": "clickhouse"},
          "targets": [{"rawSql": "SELECT ts, rule_name, severity, details FROM security.flink_alerts ORDER BY ts DESC LIMIT 200"}]
        }
      ]
    }
EOF

log "Security Posture dashboard CRD applied — operator will reconcile into Grafana"
