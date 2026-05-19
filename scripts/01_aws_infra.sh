#!/bin/bash
# Phase 1 — Step 1: Create AWS resources (KMS, ECR, SNS, IAM)
# Idempotent — safe to re-run
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

check_aws_auth
require_tool aws
require_tool jq

REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "Account: $ACCOUNT_ID  Region: $REGION"

# ── KMS key for Vault auto-unseal ────────────────────────────────────────────

log "Creating KMS key for Vault auto-unseal..."
if aws kms describe-key --key-id alias/vault-unseal &>/dev/null; then
  KMS_KEY_ID=$(aws kms describe-key \
    --key-id alias/vault-unseal \
    --query KeyMetadata.KeyId --output text)
  log "KMS key already exists: $KMS_KEY_ID"
else
  KMS_KEY_ID=$(aws kms create-key \
    --description "vault-unseal-agentic-security" \
    --query KeyMetadata.KeyId --output text)
  aws kms create-alias \
    --alias-name alias/vault-unseal \
    --target-key-id "$KMS_KEY_ID"
  log "Created KMS key: $KMS_KEY_ID"
fi
save_env KMS_KEY_ID "$KMS_KEY_ID"

# ── ECR repositories ──────────────────────────────────────────────────────────

log "Creating ECR repositories..."
for svc in \
  orchestrator-agent web-search-agent internal-data-agent \
  report-generation-agent email-agent security-gateway ciba-acp \
  tool-catalog; do
  if aws ecr describe-repositories --repository-names "agentic/$svc" &>/dev/null; then
    log "ECR repo agentic/$svc already exists"
  else
    aws ecr create-repository \
      --repository-name "agentic/$svc" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability IMMUTABLE
    log "Created ECR repo: agentic/$svc"
  fi
done

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
save_env ECR_REGISTRY "$ECR_REGISTRY"

# ── SNS topics ────────────────────────────────────────────────────────────────

log "Creating SNS topics..."
CIBA_TOPIC=$(aws sns create-topic \
  --name ciba-approvals \
  --query TopicArn --output text)
ALERT_TOPIC=$(aws sns create-topic \
  --name security-alerts \
  --query TopicArn --output text)
save_env CIBA_SNS_TOPIC "$CIBA_TOPIC"
save_env ALERT_SNS_TOPIC "$ALERT_TOPIC"
log "SNS topics: ciba-approvals=$CIBA_TOPIC, security-alerts=$ALERT_TOPIC"

# ── IAM roles for EKS Pod Identity ───────────────────────────────────────────

log "Creating IAM roles for EKS Pod Identity..."

create_pod_identity_role "vault-unseal-role" \
  "{\"Effect\":\"Allow\",\"Action\":[\"kms:Encrypt\",\"kms:Decrypt\",\"kms:DescribeKey\",\"kms:GenerateDataKey\"],\"Resource\":\"arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/${KMS_KEY_ID}\"}"

create_pod_identity_role "ciba-acp-role" \
  "{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"${CIBA_TOPIC}\"}"

create_pod_identity_role "ecr-puller-role" \
  "{\"Effect\":\"Allow\",\"Action\":[\"ecr:GetDownloadUrlForLayer\",\"ecr:BatchGetImage\",\"ecr:GetAuthorizationToken\"],\"Resource\":\"*\"}"

create_pod_identity_role "hash-verifier-role" \
  "{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"${ALERT_TOPIC}\"}"

# ── IAM role for AWS Load Balancer Controller (Pod Identity) ──────────────────

ALB_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
ALB_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${ALB_POLICY_NAME}"
ALB_ROLE_NAME="aws-load-balancer-controller-role"

log "Creating AWS Load Balancer Controller IAM policy..."
if aws iam get-policy --policy-arn "$ALB_POLICY_ARN" &>/dev/null; then
  log "ALB controller IAM policy already exists"
else
  curl -sL https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json \
    -o /tmp/alb-iam-policy.json
  aws iam create-policy \
    --policy-name "$ALB_POLICY_NAME" \
    --policy-document file:///tmp/alb-iam-policy.json
  log "ALB controller IAM policy created: $ALB_POLICY_ARN"
fi

log "Creating AWS Load Balancer Controller Pod Identity role..."
if aws iam get-role --role-name "$ALB_ROLE_NAME" &>/dev/null; then
  log "IAM role $ALB_ROLE_NAME already exists"
else
  aws iam create-role \
    --role-name "$ALB_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": { "Service": "pods.eks.amazonaws.com" },
        "Action": ["sts:AssumeRole", "sts:TagSession"]
      }]
    }' \
    --description "EKS Pod Identity role for AWS Load Balancer Controller"
  log "Created IAM role: $ALB_ROLE_NAME"
fi

aws iam attach-role-policy \
  --role-name "$ALB_ROLE_NAME" \
  --policy-arn "$ALB_POLICY_ARN"
log "Attached ALB policy to $ALB_ROLE_NAME"

# ── ACM certificate ───────────────────────────────────────────────────────────

# ── ACM certificate skipped ───────────────────────────────────────────────────
# Keycloak ALB uses HTTP for now. Add a cert later with:
#   aws acm request-certificate --domain-name auth.rj-lab.click \
#     --subject-alternative-names portal.rj-lab.click --validation-method DNS
# Then set ACM_CERT_ARN in scripts/.env and update keycloak.yaml ingress annotations.
log "Skipping ACM certificate — Keycloak ALB will use HTTP"

log "AWS infrastructure ready"
log "Saved environment to scripts/.env — source it or run scripts in order"
