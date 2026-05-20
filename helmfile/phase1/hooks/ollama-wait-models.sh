#!/bin/bash
set -euo pipefail
INSTANCE=$1
MODEL=$2

echo "Waiting for $INSTANCE pod to be created..."
for i in $(seq 1 60); do
  POD=$(kubectl get pod -n infra \
    -l "app.kubernetes.io/instance=$INSTANCE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$POD" ]; then
    echo "$INSTANCE pod found: $POD"
    break
  fi
  echo "No pod yet, waiting... ($i/60)"
  sleep 5
done

if [ -z "$POD" ]; then
  echo "ERROR: $INSTANCE pod never appeared after 300s"
  exit 1
fi

echo "Waiting for $INSTANCE pod to be Ready..."
kubectl wait pod "$POD" -n infra --for=condition=Ready --timeout=600s

echo "Confirming model $MODEL loaded in $INSTANCE..."
for i in $(seq 1 60); do
  if kubectl exec -n infra "$POD" -- ollama list 2>/dev/null | grep -q "$MODEL"; then
    echo "$INSTANCE: model $MODEL ready"
    exit 0
  fi
  echo "Waiting for model pull... ($i/60)"
  sleep 10
done

echo "ERROR: $MODEL not loaded in $INSTANCE after 600s"
exit 1
