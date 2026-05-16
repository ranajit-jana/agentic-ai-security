#!/bin/bash
# Phase 1 — Step 4: Install Helm tooling and deploy all releases via helmfile
# Idempotent — safe to re-run
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

require_tool kubectl
check_aws_auth

export REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
helm repo add istio        https://istio-release.storage.googleapis.com/charts          2>/dev/null || true
helm repo add spiffe       https://spiffe.github.io/helm-charts-hardened               2>/dev/null || true
helm repo add hashicorp    https://helm.releases.hashicorp.com                          2>/dev/null || true
helm repo add opa          https://open-policy-agent.github.io/kube-mgmt/charts        2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo add grafana      https://grafana.github.io/helm-charts                        2>/dev/null || true
helm repo update
log "Helm repos ready"

# ── Deploy via helmfile ───────────────────────────────────────────────────────

log "Running helmfile sync (this will take 15-20 min)..."
cd "${REPO_ROOT}"
helmfile sync -f "${HELMFILE_PATH}"

log "Phase 1 deployment complete"
log "Run ./scripts/validate_phase1.sh to verify"
