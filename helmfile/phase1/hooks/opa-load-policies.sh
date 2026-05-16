#!/bin/bash
set -euo pipefail

POLICY_FILE="${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/policies/baseline/agentic.rego"

echo "Loading OPA baseline policy via ConfigMap..."

kubectl create configmap opa-policy-agentic-baseline \
  --from-file=agentic.rego="$POLICY_FILE" \
  --namespace infra \
  --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl label configmap opa-policy-agentic-baseline \
  --namespace infra \
  --overwrite \
  openpolicyagent.org/policy=rego

echo "OPA baseline policy loaded: agentic/baseline"
