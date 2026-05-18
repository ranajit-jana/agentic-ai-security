#!/bin/bash
# Destroy expensive Phase 1 resources — ALB, EKS cluster, and EC2 nodes.
# Sequence: ALB ingress → LBC → LBC IAM → EKS cluster
# Keeps: Route53, ACM certificates, KMS key, ECR, SNS, IAM roles (non-LBC).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

check_aws_auth
require_tool eksctl

CLUSTER_NAME="${CLUSTER_NAME:-agentic-security}"
REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LBC_ROLE="AmazonEKSLoadBalancerControllerRole"
LBC_POLICY="AWSLoadBalancerControllerIAMPolicy"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " This will DELETE:"
echo "   • ALB (platform-public-alb ingress)"
echo "   • AWS Load Balancer Controller"
echo "   • LBC IAM role and policy"
echo "   • EKS cluster $CLUSTER_NAME and all EC2 nodes"
echo ""
echo " Region:  $REGION  |  Account: $ACCOUNT_ID"
echo ""
echo " Kept: KMS key, ECR repos, SNS topics, ACM certs, IAM roles"
echo "══════════════════════════════════════════════════════════════"
echo ""
read -r -p "Type 'destroy' to confirm: " CONFIRM
if [[ "$CONFIRM" != "destroy" ]]; then
  echo "Aborted"
  exit 0
fi

# ── Step 1: Delete ALB Ingress (lets LBC remove the ALB from AWS first) ──────
if kubectl get ingress platform-public-alb -n istio-system &>/dev/null 2>&1; then
  log "Deleting ALB Ingress — waiting for AWS ALB removal (~60s)..."
  kubectl delete ingress platform-public-alb -n istio-system
  sleep 60
  log "ALB Ingress deleted"
else
  log "ALB Ingress not found — skipping"
fi

# ── Step 2: Uninstall AWS Load Balancer Controller ────────────────────────────
if helm status aws-load-balancer-controller -n kube-system &>/dev/null 2>&1; then
  log "Uninstalling AWS Load Balancer Controller..."
  helm uninstall aws-load-balancer-controller -n kube-system
  log "LBC uninstalled"
else
  log "LBC helm release not found — skipping"
fi

# ── Step 3: Remove LBC IAM role and policy ────────────────────────────────────
if aws iam get-role --role-name "$LBC_ROLE" &>/dev/null 2>&1; then
  log "Detaching and deleting LBC IAM role..."
  aws iam detach-role-policy \
    --role-name "$LBC_ROLE" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LBC_POLICY}" 2>/dev/null || true
  aws iam delete-role --role-name "$LBC_ROLE"
  log "LBC IAM role deleted"
fi

if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LBC_POLICY}" &>/dev/null 2>&1; then
  log "Deleting LBC IAM policy..."
  aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LBC_POLICY}"
  log "LBC IAM policy deleted"
fi

# ── Step 4: Delete EKS cluster ────────────────────────────────────────────────
if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
  log "Deleting EKS cluster $CLUSTER_NAME (~10 min)..."
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait
  log "EKS cluster deleted — EC2 nodes and NAT gateway removed"
else
  log "EKS cluster $CLUSTER_NAME not found — nothing to delete"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " Done — ALB, cluster, and nodes deleted. No more EC2/NAT/ALB charges."
echo " To rebuild: bash scripts/01_aws_infra.sh && bash scripts/02_eks_cluster.sh && bash scripts/03_kubeconfig.sh && bash scripts/04_helmfile_deploy.sh"
echo "══════════════════════════════════════════════════════════════"
