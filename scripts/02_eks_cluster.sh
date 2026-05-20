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
    instanceTypes: [t3.medium, t3a.medium, t3.large]
    spot: true
    minSize: 3
    maxSize: 4
    desiredCapacity: 3
    labels: {role: system}
    privateNetworking: true
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
  - name: application
    instanceTypes: [t3.large, t3a.large, m5.large]
    spot: true
    minSize: 2
    maxSize: 4
    desiredCapacity: 2
    labels: {role: application}
    privateNetworking: true
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
  - name: observability
    instanceTypes: [t3.medium, t3a.medium]
    spot: true
    minSize: 1
    maxSize: 2
    desiredCapacity: 1
    labels: {role: observability}
    privateNetworking: true
  - name: inference
    instanceTypes: [m5.xlarge, m5a.xlarge, m5.2xlarge]
    spot: true
    minSize: 1
    maxSize: 2
    desiredCapacity: 1
    labels: {role: inference}
    privateNetworking: true
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
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
      --query 'associations[0].associationId' --output text 2>/dev/null | grep -qv "^None$"; then
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

bind_pod_identity infra      vault                    vault-unseal-role
bind_pod_identity infra      ciba-acp                 ciba-acp-role
bind_pod_identity infra      hash-verifier            hash-verifier-role
bind_pod_identity kube-system aws-load-balancer-controller aws-load-balancer-controller-role

# ── IAM OIDC provider ─────────────────────────────────────────────────────────
# Required for AWS Load Balancer Controller to assume its IAM role via IRSA.
# Each new cluster gets a fresh OIDC issuer ID so this must run on every rebuild.

log "Associating IAM OIDC provider for cluster..."
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --approve
log "OIDC provider registered"

# ── AWS Load Balancer Controller ──────────────────────────────────────────────

log "Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update eks

if helm status aws-load-balancer-controller -n kube-system &>/dev/null; then
  log "AWS Load Balancer Controller already installed"
else
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName="${CLUSTER_NAME}" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region="${REGION}" \
    --wait --timeout 180s
  log "AWS Load Balancer Controller installed"
fi

# ── NVIDIA device plugin ──────────────────────────────────────────────────────
# Required for GPU nodes — exposes nvidia.com/gpu as a schedulable resource.
# The EKS-optimised GPU AMI (used automatically with g4dn instances) includes
# the NVIDIA driver; this DaemonSet makes the GPU visible to Kubernetes.

log "Installing NVIDIA device plugin..."
kubectl apply -f \
  https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml
log "NVIDIA device plugin installed"

# ── EFS for Ollama model cache ────────────────────────────────────────────────
# All three Ollama pods share one EFS volume so llama3.1:8b is downloaded once
# and persists across pod restarts/node replacements and instance-type changes.

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' --output text)
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text)

log "Creating EFS security group..."
EFS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=ollama-efs-sg" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
if [ -z "$EFS_SG_ID" ] || [ "$EFS_SG_ID" = "None" ]; then
  EFS_SG_ID=$(aws ec2 create-security-group \
    --group-name ollama-efs-sg \
    --description "NFS access for Ollama EFS model cache" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "$EFS_SG_ID" \
    --protocol tcp --port 2049 \
    --cidr "$VPC_CIDR"
  log "Created EFS security group: $EFS_SG_ID"
else
  log "EFS security group already exists: $EFS_SG_ID"
fi

log "Creating EFS filesystem..."
EFS_ID=$(aws efs describe-file-systems \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='ollama-models']].FileSystemId" \
  --output text 2>/dev/null || echo "")
if [ -z "$EFS_ID" ]; then
  EFS_ID=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode elastic \
    --encrypted \
    --tags Key=Name,Value=ollama-models \
    --query 'FileSystemId' --output text)
  log "Created EFS filesystem: $EFS_ID"
  log "Waiting for EFS to become available..."
  aws efs wait file-system-available --file-system-id "$EFS_ID"
else
  log "EFS filesystem already exists: $EFS_ID"
fi
save_env EFS_ID "$EFS_ID"

log "Creating EFS mount targets in private subnets..."
for subnet in $PRIVATE_SUBNETS; do
  if aws efs describe-mount-targets \
      --file-system-id "$EFS_ID" \
      --query "MountTargets[?SubnetId=='${subnet}'].MountTargetId" \
      --output text | grep -q "fsmt-"; then
    log "Mount target already exists in subnet $subnet"
  else
    aws efs create-mount-target \
      --file-system-id "$EFS_ID" \
      --subnet-id "$subnet" \
      --security-groups "$EFS_SG_ID"
    log "Created mount target in subnet $subnet"
  fi
done

log "Attaching AmazonElasticFileSystemReadOnlyAccess to node instance roles..."
for role in $NODE_ROLES; do
  if aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyArn' --output text \
      | grep -q "ElasticFileSystem"; then
    log "EFS policy already attached to $role"
  else
    aws iam attach-role-policy \
      --role-name "$role" \
      --policy-arn arn:aws:iam::aws:policy/AmazonElasticFileSystemReadOnlyAccess
    log "Attached EFS policy to $role"
  fi
done

log "Installing AWS EFS CSI driver..."
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver 2>/dev/null || true
helm repo update aws-efs-csi-driver
if helm status aws-efs-csi-driver -n kube-system &>/dev/null; then
  log "aws-efs-csi-driver already installed — skipping"
else
  helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set controller.region="${REGION}" \
    --wait --timeout 180s
  log "aws-efs-csi-driver installed"
fi

log "Creating EFS StorageClass and shared PV/PVC for Ollama models..."
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: efs-ollama-models
spec:
  capacity:
    storage: 50Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: efs-sc
  csi:
    driver: efs.csi.aws.com
    volumeHandle: ${EFS_ID}
---
apiVersion: v1
kind: Namespace
metadata:
  name: infra
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models-shared
  namespace: infra
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 50Gi
  volumeName: efs-ollama-models
EOF
log "EFS PVC ollama-models-shared ready in infra namespace"

log "EKS cluster ready — all nodegroups on spot"
