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

# ── Private subnets + NAT Gateway in the default VPC ─────────────────────────
# The default VPC (172.31.0.0/16) already has public subnets and an IGW.
# We only add private subnets (for EKS nodes + EFS) and a NAT Gateway.
# These are created once here and reused across every cluster rebuild.

CLUSTER_NAME="agentic-security"

log "Locating default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)
[ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ] && die "No default VPC found in $REGION"
log "Default VPC: $VPC_ID"
save_env VPC_ID "$VPC_ID"

# Read the existing public subnets (one per AZ) and their AZs
log "Reading existing public subnets..."
readarray -t PUB_SUBNET_IDS < <(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=defaultForAz,Values=true" \
  --query 'Subnets | sort_by(@, &AvailabilityZone)[].SubnetId' \
  --output text | tr '\t' '\n')
readarray -t PUB_SUBNET_AZS < <(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=defaultForAz,Values=true" \
  --query 'Subnets | sort_by(@, &AvailabilityZone)[].AvailabilityZone' \
  --output text | tr '\t' '\n')
[ "${#PUB_SUBNET_IDS[@]}" -lt 2 ] && die "Expected at least 2 default public subnets in $VPC_ID"
log "Public subnets: ${PUB_SUBNET_IDS[*]}"

# Tag and name the existing public subnets for EKS ALB discovery
log "Tagging default public subnets for EKS..."
for i in "${!PUB_SUBNET_IDS[@]}"; do
  sub="${PUB_SUBNET_IDS[$i]}"
  az="${PUB_SUBNET_AZS[$i]}"
  aws ec2 create-tags --resources "$sub" --tags \
    "Key=Name,Value=public-${az}" \
    "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared" \
    "Key=kubernetes.io/role/elb,Value=1"
done

# Create one private subnet per AZ (172.31.48/64/80.0/20 — beyond the default /20 blocks)
# Default subnets occupy 172.31.0-47.x; private subnets start at 172.31.48.0
log "Creating private subnets (one per AZ)..."
declare -a PRI_CIDRS=("172.31.48.0/20" "172.31.64.0/20" "172.31.80.0/20")
FIRST_PUB_SUBNET="${PUB_SUBNET_IDS[0]}"

for i in "${!PUB_SUBNET_AZS[@]}"; do
  az="${PUB_SUBNET_AZS[$i]}"
  cidr="${PRI_CIDRS[$i]}"
  name="private-${az}"
  existing=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=${name}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
  if [ -z "$existing" ] || [ "$existing" = "None" ]; then
    sub_id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
      --cidr-block "$cidr" --availability-zone "$az" \
      --query 'Subnet.SubnetId' --output text)
    aws ec2 create-tags --resources "$sub_id" --tags \
      Key=Name,Value="${name}" \
      "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared" \
      "Key=kubernetes.io/role/internal-elb,Value=1"
    log "Created private subnet $name ($az $cidr): $sub_id"
  else
    log "Private subnet $name already exists: $existing"
    # Ensure tags are present (idempotent re-run)
    aws ec2 create-tags --resources "$existing" --tags \
      "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared" \
      "Key=kubernetes.io/role/internal-elb,Value=1"
  fi
done

# NAT Gateway — single, in the first public subnet
log "Creating NAT Gateway..."
NAT_GW_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=subnet-id,Values=${FIRST_PUB_SUBNET}" \
           "Name=state,Values=available,pending" \
  --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)
if [ -z "$NAT_GW_ID" ] || [ "$NAT_GW_ID" = "None" ]; then
  EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
    --query 'AllocationId' --output text)
  NAT_GW_ID=$(aws ec2 create-nat-gateway \
    --subnet-id "$FIRST_PUB_SUBNET" \
    --allocation-id "$EIP_ALLOC" \
    --tag-specifications \
      "ResourceType=natgateway,Tags=[{Key=Name,Value=agentic-security-natgw}]" \
    --query 'NatGateway.NatGatewayId' --output text)
  log "Waiting for NAT Gateway $NAT_GW_ID..."
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW_ID"
  log "NAT Gateway ready: $NAT_GW_ID"
else
  log "NAT Gateway already exists: $NAT_GW_ID"
fi
save_env NAT_GW_ID "$NAT_GW_ID"

# Private route table — 0.0.0.0/0 → NAT GW; associate all private subnets
log "Creating private route table..."
PRI_RT=$(aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=private-rt" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
if [ -z "$PRI_RT" ] || [ "$PRI_RT" = "None" ]; then
  PRI_RT=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-tags --resources "$PRI_RT" --tags Key=Name,Value=private-rt
  aws ec2 create-route --route-table-id "$PRI_RT" \
    --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID"
  for i in "${!PUB_SUBNET_AZS[@]}"; do
    az="${PUB_SUBNET_AZS[$i]}"
    sub=$(aws ec2 describe-subnets \
      --filters "Name=tag:Name,Values=private-${az}" \
               "Name=vpc-id,Values=${VPC_ID}" \
      --query 'Subnets[0].SubnetId' --output text)
    aws ec2 associate-route-table --route-table-id "$PRI_RT" \
      --subnet-id "$sub" >/dev/null
  done
  log "Created private route table: $PRI_RT"
else
  log "Private route table already exists: $PRI_RT"
fi

log "AWS infrastructure ready"
log "Saved environment to scripts/.env — source it or run scripts in order"
