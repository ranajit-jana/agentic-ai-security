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

# ── Install helm (needed for EBS CSI driver below) ────────────────────────────

HELM_VERSION="v3.21.0"
HELM_BIN="${HOME}/.local/bin/helm"

if command -v helm &>/dev/null; then
  log "helm already installed: $(helm version --short)"
else
  log "Installing helm ${HELM_VERSION}..."
  mkdir -p "${HOME}/.local/bin"
  curl -sL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /tmp
  mv /tmp/linux-amd64/helm "${HELM_BIN}"
  chmod +x "${HELM_BIN}"
  log "helm installed"
fi
export PATH="${HOME}/.local/bin:${PATH}"

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
  version: "1.35"
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
    minSize: 3
    maxSize: 4
    desiredCapacity: 3
    labels: {role: system}
    privateNetworking: true
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
  - name: application
    instanceType: t3.large
    minSize: 2
    maxSize: 4
    desiredCapacity: 2
    labels: {role: application}
    privateNetworking: true
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
  - name: observability
    instanceType: t3.medium
    minSize: 1
    maxSize: 2
    desiredCapacity: 1
    labels: {role: observability}
    privateNetworking: true
EOF
  log "Cluster created"
fi

save_env CLUSTER_NAME "$CLUSTER_NAME"

# ── EBS CSI driver ────────────────────────────────────────────────────────────
# eksctl addon install requires iam:GetOpenIDConnectProvider which aws-dev lacks.
# Workaround: attach the managed policy to every node instance role, then install
# the driver via Helm so CSI pods use the node instance profile for EBS access.

log "Attaching AmazonEBSCSIDriverPolicy to node instance roles..."
NODE_ROLES=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, \`${CLUSTER_NAME}\`) && contains(RoleName, \`NodeInstanceRole\`)].RoleName" \
  --output text)

for role in $NODE_ROLES; do
  if aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyArn' --output text \
      | grep -q "AmazonEBSCSIDriverPolicy"; then
    log "AmazonEBSCSIDriverPolicy already attached to $role"
  else
    aws iam attach-role-policy \
      --role-name "$role" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
    log "Attached AmazonEBSCSIDriverPolicy to $role"
  fi
done

log "Installing aws-ebs-csi-driver via Helm..."
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver 2>/dev/null || true
helm repo update aws-ebs-csi-driver

if helm status aws-ebs-csi-driver -n kube-system &>/dev/null; then
  log "aws-ebs-csi-driver already installed — skipping"
else
  helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
    --namespace kube-system \
    --set controller.region="${REGION}" \
    --wait --timeout 180s
  log "aws-ebs-csi-driver installed"
fi

log "Creating gp2-csi StorageClass and setting as default..."
kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  type: gp2
YAML
log "gp2-csi StorageClass ready and set as default"

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

# ── IAM OIDC provider ─────────────────────────────────────────────────────────
# Required for AWS Load Balancer Controller to assume its IAM role via IRSA.
# Each new cluster gets a fresh OIDC issuer ID so this must run on every rebuild.

log "Associating IAM OIDC provider for cluster..."
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --approve
log "OIDC provider registered"

log "EKS cluster ready"
