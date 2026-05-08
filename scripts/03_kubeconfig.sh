#!/bin/bash
# Phase 1 — Step 3: Update kubeconfig to point at the new EKS cluster
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

require_tool aws
require_tool kubectl
check_aws_auth

CLUSTER_NAME="${CLUSTER_NAME:-agentic-security}"
REGION=$(aws configure get region)

log "Updating kubeconfig for cluster: $CLUSTER_NAME"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

log "Verifying cluster connectivity..."
kubectl get nodes -o wide

log "kubeconfig ready — kubectl is now pointed at $CLUSTER_NAME"
