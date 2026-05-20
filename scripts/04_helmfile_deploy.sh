#!/bin/bash
# Phase 1 — Step 4: Install Helm tooling and deploy all releases via helmfile
# Idempotent — safe to re-run
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

require_tool kubectl
check_aws_auth

export REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION=$(aws configure get region)
HELMFILE_PATH="${REPO_ROOT}/helmfile/phase1/helmfile.yaml.gotmpl"

# ── Install helm ──────────────────────────────────────────────────────────────

HELM_VERSION="v3.21.0"
HELM_BIN="${HOME}/.local/bin/helm"

if command -v helm &>/dev/null; then
  log "helm already installed: $(helm version --short)"
else
  log "Installing helm ${HELM_VERSION} to ${HELM_BIN}..."
  mkdir -p "${HOME}/.local/bin"
  curl -sL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C /tmp
  mv /tmp/linux-amd64/helm "${HELM_BIN}"
  chmod +x "${HELM_BIN}"
  export PATH="${HOME}/.local/bin:${PATH}"
  log "helm installed: $(helm version --short)"
fi

# Ensure ~/.local/bin is on PATH for subsequent commands in this script
export PATH="${HOME}/.local/bin:${PATH}"

# ── Install helm-diff plugin ──────────────────────────────────────────────────

if helm plugin list 2>/dev/null | grep -q "^diff"; then
  log "helm-diff plugin already installed"
else
  log "Installing helm-diff plugin..."
  helm plugin install https://github.com/databus23/helm-diff
  log "helm-diff installed"
fi

# ── Install helmfile ──────────────────────────────────────────────────────────

HELMFILE_VERSION="v1.5.1"
HELMFILE_BIN="${HOME}/.local/bin/helmfile"

if command -v helmfile &>/dev/null; then
  log "helmfile already installed: $(helmfile --version)"
else
  log "Installing helmfile ${HELMFILE_VERSION}..."
  curl -sL "https://github.com/helmfile/helmfile/releases/download/${HELMFILE_VERSION}/helmfile_linux_amd64.tar.gz" \
    | tar xz -C /tmp helmfile
  mv /tmp/helmfile "${HELMFILE_BIN}"
  chmod +x "${HELMFILE_BIN}"
  log "helmfile installed"
fi

# ── Add helm chart repositories ───────────────────────────────────────────────

log "Adding/updating helm chart repositories..."
helm repo add istio          https://istio-release.storage.googleapis.com/charts          2>/dev/null || true
helm repo add spiffe         https://spiffe.github.io/helm-charts-hardened               2>/dev/null || true
helm repo add hashicorp      https://helm.releases.hashicorp.com                          2>/dev/null || true
helm repo add opa            https://open-policy-agent.github.io/kube-mgmt/charts        2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts  2>/dev/null || true
helm repo add grafana        https://grafana.github.io/helm-charts                        2>/dev/null || true
helm repo add ollama         https://otwld.github.io/ollama-helm                          2>/dev/null || true
helm repo add permitio       https://permitio.github.io/opal-helm-chart                   2>/dev/null || true
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver     2>/dev/null || true
helm repo update
log "Helm repos ready"

# ── EFS CSI driver + shared Ollama model PVC ─────────────────────────────────
# Runs here (not in 02_eks_cluster.sh) because:
#   1. infra namespace is created by helmfile on first sync
#   2. EFS_ID is already saved to .env by 02_eks_cluster.sh

log "Attaching EFS read policy to node instance roles..."
NODE_ROLES=$(aws iam list-roles \
  --query "Roles[?contains(RoleName, \`agentic-security\`) && contains(RoleName, \`NodeInstanceRole\`)].RoleName" \
  --output text)
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

log "Ensuring EFS CSI driver is installed..."
if helm status aws-efs-csi-driver -n kube-system &>/dev/null; then
  log "aws-efs-csi-driver already installed — skipping"
else
  helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set controller.region="${REGION}" \
    --wait --timeout 180s
  log "aws-efs-csi-driver installed"
fi

log "Ensuring ollama-models-shared PVC exists..."
if kubectl get pvc ollama-models-shared -n infra &>/dev/null; then
  log "ollama-models-shared PVC already exists — skipping"
else
  if [ -z "${EFS_ID:-}" ]; then
    log "ERROR: EFS_ID not set in .env — run 02_eks_cluster.sh first"
    exit 1
  fi
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
    storage: 30Gi
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
      storage: 30Gi
  volumeName: efs-ollama-models
EOF
  log "ollama-models-shared PVC created (backed by EFS ${EFS_ID})"
fi

# ── Deploy via helmfile ───────────────────────────────────────────────────────

log "Running helmfile sync (this will take 20-30 min — Ollama pulls ~4.7 GB on first run)..."
cd "${REPO_ROOT}"
helmfile sync -f "${HELMFILE_PATH}"

log "Deployment complete (Phase 1 + Phase 2)"

# ── Wire Route 53 ALIAS records → ALB ────────────────────────────────────────

R53_ZONE_ID="${R53_ZONE_ID:-Z02035941A90NEJDXI763}"
DOMAIN="${DOMAIN:-rj-lab.click}"
SUBDOMAINS=("auth" "gateway" "keycloak" "grafana")

log "Waiting for ALB hostname from platform-public-alb ingress..."
ALB_HOSTNAME=""
for i in $(seq 1 20); do
  ALB_HOSTNAME=$(kubectl get ingress platform-public-alb -n istio-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$ALB_HOSTNAME" ]; then break; fi
  log "  [$i/20] ALB not ready yet, retrying in 15s..."
  sleep 15
done

if [ -z "$ALB_HOSTNAME" ]; then
  log "WARNING: ALB hostname not available after 5 min — skipping Route 53 update. Re-run this script once the ALB is ready."
else
  log "ALB hostname: $ALB_HOSTNAME"
  ALB_ZONE_ID=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?DNSName=='${ALB_HOSTNAME}'].CanonicalHostedZoneId" \
    --output text)

  CHANGES="["
  for SUB in "${SUBDOMAINS[@]}"; do
    CHANGES+=$(cat <<EOF
{
  "Action": "UPSERT",
  "ResourceRecordSet": {
    "Name": "${SUB}.${DOMAIN}",
    "Type": "A",
    "AliasTarget": {
      "HostedZoneId": "${ALB_ZONE_ID}",
      "DNSName": "${ALB_HOSTNAME}",
      "EvaluateTargetHealth": true
    }
  }
},
EOF
)
  done
  CHANGES="${CHANGES%,}]"

  aws route53 change-resource-record-sets \
    --hosted-zone-id "$R53_ZONE_ID" \
    --change-batch "{\"Changes\": ${CHANGES}}" \
    --query 'ChangeInfo.Status' --output text
  log "Route 53 ALIAS records created for: ${SUBDOMAINS[*]} → ${ALB_HOSTNAME}"
fi

log "Run ./scripts/validate.sh to verify"
