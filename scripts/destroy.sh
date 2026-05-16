#!/bin/bash
# Destroy expensive Phase 1 resources — EKS cluster and EC2 nodes.
# Keeps: Route53, ACM certificate, KMS key, ECR, SNS, IAM roles.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

check_aws_auth
require_tool eksctl

CLUSTER_NAME="${CLUSTER_NAME:-agentic-security}"
REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " This will DELETE the EKS cluster and all EC2 nodes"
echo " Cluster:  $CLUSTER_NAME"
echo " Region:   $REGION"
echo " Account:  $ACCOUNT_ID"
echo ""
echo " Kept: KMS key, ECR repos, SNS topics, IAM roles"
echo "══════════════════════════════════════════════════════════════"
echo ""
read -r -p "Type 'destroy' to confirm: " CONFIRM
if [[ "$CONFIRM" != "destroy" ]]; then
  echo "Aborted"
  exit 0
fi

if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
  log "Deleting EKS cluster $CLUSTER_NAME (~10 min)..."
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait
  log "EKS cluster deleted — EC2 nodes and NAT gateway removed"
else
  log "EKS cluster $CLUSTER_NAME not found — nothing to delete"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " Done — cluster deleted, no more EC2/NAT charges"
echo " To rebuild: bash scripts/01_aws_infra.sh (idempotent) && bash scripts/02_eks_cluster.sh && bash scripts/03_kubeconfig.sh && bash scripts/04_helmfile_deploy.sh"
echo "══════════════════════════════════════════════════════════════"
