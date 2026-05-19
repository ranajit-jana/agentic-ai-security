#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../../../scripts/lib/common.sh"

log "Deploying Flink security correlator job..."

kubectl apply -f - <<'EOF'
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata:
  name: security-correlator
  namespace: observability
spec:
  image: flink:1.18-java11
  flinkVersion: v1_18
  flinkConfiguration:
    taskmanager.numberOfTaskSlots: "2"
    state.backend: hashmap
    execution.checkpointing.interval: "30s"
  serviceAccount: flink
  jobManager:
    resource:
      memory: "1024m"
      cpu: 0.5
  taskManager:
    replicas: 2
    resource:
      memory: "2048m"
      cpu: 1.0
  job:
    jarURI: local:///opt/flink/usrlib/security-correlator.jar
    parallelism: 2
    upgradeMode: stateless
    args:
      - "--kafka-brokers"
      - "kafka.observability.svc.cluster.local:9092"
      - "--clickhouse-url"
      - "http://clickhouse.observability.svc.cluster.local:8123"
      - "--sns-topic"
      - "$(kubectl get secret aws-config -n infra -o jsonpath='{.data.alert_topic}' | base64 -d)"
EOF

log "Waiting for Flink job to start..."
for i in $(seq 1 20); do
  STATUS=$(kubectl get flinkdeployment security-correlator -n observability \
    -o jsonpath='{.status.jobStatus.state}' 2>/dev/null || echo "UNKNOWN")
  [ "$STATUS" = "RUNNING" ] && { log "Flink job running"; break; }
  log "  [$i/20] status=$STATUS — retrying in 10s..."
  sleep 10
done

log "Flink CEP correlator deployed — rules active:
  - injection → tool call within 60s (same agent_id)
  - probe → inject → exfiltrate sequence within 2 min
  - KubeArmor block ⋈ GuardDuty same node within 5 min
  - Biscuit violations > 3 in 10 min"
