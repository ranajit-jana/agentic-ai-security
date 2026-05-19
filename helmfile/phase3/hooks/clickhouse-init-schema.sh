#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../../../scripts/lib/common.sh"

CH_URL="http://clickhouse.observability.svc.cluster.local:8123"

log "Waiting for ClickHouse to be ready..."
for i in $(seq 1 30); do
  curl -sf "${CH_URL}/ping" >/dev/null 2>&1 && { log "ClickHouse ready"; break; }
  log "  [$i/30] not ready yet — retrying in 5s..."
  sleep 5
done

log "Creating ClickHouse schema..."

# All raw enriched events — TTL 1 day (matches nightly destroy cycle)
curl -sf "${CH_URL}" --data "
CREATE DATABASE IF NOT EXISTS security;

CREATE TABLE IF NOT EXISTS security.security_events (
    timestamp        DateTime64(3),
    event_source     LowCardinality(String),
    agent_id         String,
    node_name        LowCardinality(String),
    event_type       LowCardinality(String),
    decision         LowCardinality(String),
    scan_result      LowCardinality(String),
    severity         LowCardinality(String),
    raw              String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(timestamp)
ORDER BY (timestamp, event_source, agent_id)
TTL timestamp + INTERVAL 1 DAY DELETE;
"

# Flink CEP correlation hits — TTL 7 days (keep longer for incident review)
curl -sf "${CH_URL}" --data "
CREATE TABLE IF NOT EXISTS security.correlation_alerts (
    timestamp        DateTime64(3),
    rule_name        LowCardinality(String),
    agent_id         String,
    node_name        LowCardinality(String),
    severity         LowCardinality(String),
    detail           String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(timestamp)
ORDER BY (timestamp, rule_name)
TTL timestamp + INTERVAL 7 DAY DELETE;
"

# Daily gap analysis results — TTL 30 days
curl -sf "${CH_URL}" --data "
CREATE TABLE IF NOT EXISTS security.gap_analysis (
    run_date         Date,
    total_agents     UInt32,
    agents_with_opa  UInt32,
    agents_with_cedar UInt32,
    agents_with_kubearmor UInt32,
    coverage_pct     Float32,
    gaps             String
)
ENGINE = MergeTree()
ORDER BY run_date
TTL run_date + INTERVAL 30 DAY DELETE;
"

log "ClickHouse schema created — tables: security_events, correlation_alerts, gap_analysis"
