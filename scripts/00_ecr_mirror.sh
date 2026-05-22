#!/bin/bash
# Step 0: Mirror ALL public images to ECR — fast regional pulls, no rate limits.
# Run once before cluster setup or whenever an image tag changes.
# Idempotent — skips images already present in ECR at the correct tag.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_env

require_tool aws
check_aws_auth

REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Install crane if not present (handles multi-arch manifests correctly)
CRANE_BIN="${HOME}/.local/bin/crane"
if ! command -v crane &>/dev/null; then
  log "Installing crane..."
  mkdir -p "${HOME}/.local/bin"
  curl -sL "https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz" \
    | tar xz -C "${HOME}/.local/bin" crane
  chmod +x "${CRANE_BIN}"
  log "crane installed"
fi
export PATH="${HOME}/.local/bin:${PATH}"

log "Logging in to ECR..."
aws ecr get-login-password --region "$REGION" \
  | crane auth login --username AWS --password-stdin "$ECR"

# mirror <src-image:tag> <ecr-repo> <ecr-tag>
mirror() {
  local src="$1" repo="$2" tag="$3"
  local dest="${ECR}/${repo}:${tag}"

  if aws ecr describe-images --repository-name "$repo" \
      --image-ids imageTag="$tag" --region "$REGION" &>/dev/null; then
    log "Already mirrored: ${repo}:${tag} — skipping"
    return
  fi

  aws ecr create-repository --repository-name "$repo" \
    --image-scanning-configuration scanOnPush=true \
    --region "$REGION" &>/dev/null || true

  log "Copying $src → $dest (linux/amd64)..."
  crane copy --platform linux/amd64 "$src" "$dest"
  log "Mirrored: $dest"
}

# ── Base images (DockerHub) ───────────────────────────────────────────────────
mirror python:3.11-slim                          mirror/python          3.11-slim
mirror postgres:16.9-alpine3.21                  mirror/postgres        16.9-alpine3.21
mirror postgres:alpine                           mirror/postgres        alpine
mirror redis:7.4.3-alpine3.21                    mirror/redis           7.4.3-alpine3.21
mirror busybox:1.36.1                            mirror/busybox         1.36.1
mirror busybox:1.31.1                            mirror/busybox         1.31.1

# ── HashiCorp ─────────────────────────────────────────────────────────────────
mirror hashicorp/vault:1.21.2                    mirror/vault           1.21.2
mirror hashicorp/vault-k8s:1.7.2                 mirror/vault-k8s       1.7.2
mirror hashicorp/consul:1.22.7                   mirror/consul          1.22.7

# ── OPA ───────────────────────────────────────────────────────────────────────
mirror openpolicyagent/opa:0.40.0                mirror/opa             0.40.0
mirror openpolicyagent/kube-mgmt:4.1.1           mirror/kube-mgmt       4.1.1

# ── OpenTelemetry ─────────────────────────────────────────────────────────────
mirror otel/opentelemetry-collector-contrib:0.152.0  mirror/otel-collector  0.152.0

# ── Grafana stack ─────────────────────────────────────────────────────────────
mirror grafana/grafana:12.3.1                    mirror/grafana         12.3.1
mirror ghcr.io/grafana/grafana-operator:v5.23.0  mirror/grafana-operator  v5.23.0
mirror grafana/loki:3.6.7                        mirror/loki            3.6.7
mirror grafana/promtail:3.5.1                    mirror/promtail        3.5.1
mirror grafana/tempo:2.9.0                       mirror/tempo           2.9.0
mirror kiwigrid/k8s-sidecar:2.5.0                mirror/k8s-sidecar     2.5.0
mirror curlimages/curl:8.9.1                     mirror/curl            8.9.1
mirror bats/bats:v1.4.1                          mirror/bats            v1.4.1
mirror bats/bats:1.8.2                           mirror/bats            1.8.2

# ── Prometheus stack ──────────────────────────────────────────────────────────
mirror quay.io/prometheus/prometheus:v3.11.3                 mirror/prometheus                v3.11.3
mirror quay.io/prometheus/node-exporter:v1.11.1              mirror/node-exporter             v1.11.1
mirror registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.18.0  mirror/kube-state-metrics  v2.18.0
mirror quay.io/prometheus-operator/prometheus-config-reloader:v0.91.0  mirror/prometheus-config-reloader  v0.91.0

# ── Promtail config-reloader ──────────────────────────────────────────────────
mirror ghcr.io/jimmidyson/configmap-reload:v0.12.0           mirror/configmap-reload          v0.12.0

# ── Ollama ────────────────────────────────────────────────────────────────────
mirror ollama/ollama:0.23.2                      mirror/ollama          0.23.2

# ── OPAL (Permit.io) ─────────────────────────────────────────────────────────
mirror permitio/opal-server:0.7.12               mirror/opal-server     0.7.12
mirror permitio/opal-client:0.7.12               mirror/opal-client     0.7.12

# ── GHCR / Quay ───────────────────────────────────────────────────────────────
mirror ghcr.io/berriai/litellm:main-latest        mirror/litellm         main-latest
mirror quay.io/keycloak/keycloak:26.2.5           mirror/keycloak        26.2.5

log "All images mirrored to ECR (${ECR}/mirror/)"
log "Run scripts/01_aws_infra.sh next"
