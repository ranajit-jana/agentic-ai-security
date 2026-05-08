#!/bin/bash
# Phase 1 — Step 2: Create EKS cluster + node groups
# Requires: eksctl, aws CLI, scripts/.env populated by 01_aws_infra.sh
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

require_tool eksctl
require_tool aws
check_aws_auth

CLUSTER_NAME="agentic-security"
REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ── Create cluster (idempotent) ───────────────────────────────────────────────

if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
  log "Cluster $CLUSTER_NAME already exists — skipping creation"
else
  log "Creating EKS cluster $CLUSTER_NAME (this takes ~15 min)..."
  cat <<EOF | eksctl create cluster -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "1.29"
addons:
  - name: vpc-cni
    version: latest
  - name: coredns
    version: latest
  - name: kube-proxy
    version: latest
  - name: eks-pod-identity-agent
    version: latest
vpc:
  nat:
    gateway: Single
managedNodeGroups:
  - name: system
    instanceType: t3.medium
    minSize: 2
    maxSize: 2
    desiredCapacity: 2
    labels: {role: system}
    privateNetworking: true
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
  - name: application
    instanceType: m5.2xlarge
    minSize: 3
    maxSize: 6
    desiredCapacity: 3
    labels: {role: application}
    privateNetworking: true
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
  - name: observability
    instanceType: m5.xlarge
    minSize: 2
    maxSize: 2
    desiredCapacity: 2
    labels: {role: observability}
    privateNetworking: true
EOF
  log "Cluster created"
fi

save_env CLUSTER_NAME "$CLUSTER_NAME"

# ── Pod Identity associations ─────────────────────────────────────────────────

log "Binding EKS Pod Identity associations..."

bind_pod_identity() {
  local namespace="$1" sa="$2" role="$3"
  if aws eks list-pod-identity-associations \
      --cluster-name "$CLUSTER_NAME" \
      --namespace "$namespace" \
      --service-account "$sa" \
      --query 'associations[0].associationId' --output text 2>/dev/null | grep -q "^pa-"; then
    log "Pod identity already bound: $namespace/$sa"
  else
    aws eks create-pod-identity-association \
      --cluster-name "$CLUSTER_NAME" \
      --namespace "$namespace" \
      --service-account "$sa" \
      --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${role}"
    log "Bound pod identity: $namespace/$sa → $role"
  fi
}

bind_pod_identity infra vault    vault-unseal-role
bind_pod_identity infra ciba-acp ciba-acp-role

log "EKS cluster ready"
