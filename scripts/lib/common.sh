#!/bin/bash
# Shared helper functions for all phase scripts

set -euo pipefail

ENV_FILE="${ENV_FILE:-scripts/.env}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

# Persist a key=value to scripts/.env so subsequent scripts can source it
save_env() {
  local key="$1" value="$2"
  mkdir -p "$(dirname "$ENV_FILE")"
  # Remove existing entry if present
  grep -v "^${key}=" "$ENV_FILE" 2>/dev/null > "${ENV_FILE}.tmp" || true
  echo "${key}=${value}" >> "${ENV_FILE}.tmp"
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
  fi
}

# Create an IAM role for EKS Pod Identity with a given inline policy
# Usage: create_pod_identity_role <role-name> <policy-json>
create_pod_identity_role() {
  local role_name="$1"
  local policy_json="$2"
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text)

  local trust_doc
  trust_doc=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
JSON
)

  if aws iam get-role --role-name "$role_name" &>/dev/null; then
    log "IAM role $role_name already exists — skipping creation"
  else
    aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document "$trust_doc" \
      --description "EKS Pod Identity role for $role_name"
    log "Created IAM role: $role_name"
  fi

  local full_policy
  full_policy=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [${policy_json}]
}
JSON
)

  aws iam put-role-policy \
    --role-name "$role_name" \
    --policy-name "${role_name}-inline" \
    --policy-document "$full_policy"

  log "Attached inline policy to $role_name"
}

# Wait for a kubectl resource to become available
wait_for_pod_ready() {
  local namespace="$1" label="$2" timeout="${3:-120s}"
  kubectl wait pod \
    -n "$namespace" \
    -l "$label" \
    --for=condition=Ready \
    --timeout="$timeout"
}

require_tool() {
  command -v "$1" &>/dev/null || die "'$1' is not installed or not in PATH"
}

check_aws_auth() {
  aws sts get-caller-identity &>/dev/null || \
    die "AWS credentials not configured. Run: aws configure"
}
