#!/bin/bash
# Destroy expensive resources — ALB, EKS cluster, and EC2 nodes.
# Sequence: ALB ingress → LBC helm release → EKS cluster
# Keeps everything free: Route53, ACM, KMS, ECR, SNS, IAM roles and policies.
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
echo " This will DELETE:"
echo "   • ALB (platform-public-alb ingress)"
echo "   • AWS Load Balancer Controller (helm release)"
echo "   • EKS cluster $CLUSTER_NAME and all EC2 nodes"
echo ""
echo " Region:  $REGION  |  Account: $ACCOUNT_ID"
echo ""
echo " Kept (free): KMS key, ECR, SNS, ACM, Route 53, IAM roles/policies"
echo " Kept (paid ~\$1.50/mo): EFS ollama-models — survives rebuild, no re-download"
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

# ── Step 3: LBC IAM role and policy — kept (IAM is free, reused on rebuild) ───
log "Skipping LBC IAM role/policy deletion — IAM resources are free and reused on rebuild"

# ── Step 4: Delete EKS cluster ────────────────────────────────────────────────
if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
  log "Deleting EKS cluster $CLUSTER_NAME (~10 min)..."
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait
  log "EKS cluster deleted — EC2 nodes and NAT gateway removed"
else
  log "EKS cluster $CLUSTER_NAME not found — nothing to delete"
fi

# ── Step 5: Delete IAM OIDC provider ─────────────────────────────────────────
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn, '${CLUSTER_NAME}') || contains(Arn, 'oidc.eks.${REGION}')].Arn" \
  --output text 2>/dev/null || true)
if [ -n "$OIDC_ARN" ]; then
  log "Deleting IAM OIDC provider..."
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"
  log "OIDC provider deleted"
else
  log "OIDC provider not found — skipping"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " Done — ALB, cluster, nodes, and OIDC provider deleted."
echo " No more EC2/NAT/ALB charges."
echo ""
echo " To rebuild (skip step 1 — infra persists):"
echo "   bash scripts/02_eks_cluster.sh"
echo "   bash scripts/03_kubeconfig.sh"
echo "   bash scripts/04_helmfile_deploy.sh"
echo "══════════════════════════════════════════════════════════════"
