# Implementation Plan — Phase 3: Threat Management and Posture

## Automation Approach

AWS GuardDuty and GitHub Actions OIDC setup are pre-Kubernetes operations handled by scripts. CI/CD workflow files are written to the repository by script. All Kubernetes workloads are deployed with a single Helmfile command.

Phase 3 Helmfile releases reference Phase 1 and Phase 2 releases via `needs:`, and some upgrade existing releases (Grafana for the posture dashboard).

```
scripts/
  phase3/
    00_prereqs_phase3.sh     ← verify Phase 2 complete + KubeArmor policies ready
    01_guardduty.sh          ← AWS CLI: enable GuardDuty EKS runtime monitoring
    02_cicd_workflows.sh     ← write GitHub Actions workflow files to repo
    03_github_oidc.sh        ← AWS IAM OIDC role for GitHub Actions
    validate_phase3.sh       ← automated validation checks

helmfile/
  phase3/
    helmfile.yaml.gotmpl            ← all Phase 3 releases, ordering, hooks
    values/
      kubearmor.yaml
      kubearmor-operator.yaml
      kubearmor-controller.yaml
      opensearch.yaml
      opensearch-dashboards.yaml
      gap-analysis.yaml
    hooks/
      kubearmor-apply-baseline.sh
      opensearch-load-rules.sh
      grafana-provision-dashboard.sh
```

**Run Phase 3:**
```bash
./scripts/phase3/00_prereqs_phase3.sh
./scripts/phase3/01_guardduty.sh
./scripts/phase3/02_cicd_workflows.sh
./scripts/phase3/03_github_oidc.sh
helmfile -f helmfile/phase3/helmfile.yaml.gotmpl sync
./scripts/validate_phase3.sh
```

---

## Manual Steps — Phase 3

---

> **MANUAL STEP 7 — Review KubeArmor Discovery Engine Policies**
>
> Must be completed **before running Phase 3**. Requires agents to have operated
> normally in Phase 2 for at least **48 hours** (see MANUAL STEP 6 in Phase 2).
>
> 1. Generate candidate policies from observed runtime behavior:
>    ```bash
>    karmor discover --namespace agents --format yaml > discovered-policies.yaml
>    karmor discover --namespace tools --format yaml >> discovered-policies.yaml
>    ```
> 2. Review `discovered-policies.yaml`:
>    - Confirm each process allowlist contains only expected agent binaries
>    - Confirm network rules match expected destinations (Anthropic API, internal services)
>    - Remove any rules that allow `/bin/sh` or `/bin/bash` — agents must never spawn shells
>    - Tighten any file access rules that are broader than needed
> 3. Save the reviewed file:
>    ```bash
>    cp discovered-policies.yaml policies/kubearmor-baseline.yaml
>    git add policies/kubearmor-baseline.yaml
>    git commit -m "Add KubeArmor baseline policies from discovery"
>    ```
> 4. Phase 3 Helmfile applies this file automatically via the `kubearmor-apply-baseline.sh` hook.

---

> **MANUAL STEP 8 — GitHub Actions Secrets**
>
> Required before `02_cicd_workflows.sh` and `03_github_oidc.sh` can function.
>
> In your GitHub repository → **Settings** → **Secrets and variables** → **Actions**:
>
> | Secret Name | Value |
> |---|---|
> | `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
> | `AWS_REGION` | Your AWS region (e.g. `us-east-1`) |
> | `ECR_REGISTRY` | `<account-id>.dkr.ecr.<region>.amazonaws.com` |
> | `GATEWAY_TEST_URL` | Internal URL of security gateway (via bastion or VPN) |
> | `ANTHROPIC_API_KEY` | Your Anthropic API key |
>
> `03_github_oidc.sh` creates the IAM OIDC provider and role so GitHub Actions can
> assume AWS credentials without storing long-lived keys.

---

> **MANUAL STEP 9 — OpenSearch Admin Password**
>
> OpenSearch requires a custom admin password set before first start.
>
> 1. Generate a strong password:
>    ```bash
>    openssl rand -base64 24
>    ```
> 2. Store in Vault (Phase 1 must be running):
>    ```bash
>    vault kv put secret/opensearch admin_password=<generated-password>
>    ```
> 3. Phase 3 Helmfile reads the password from Vault automatically when deploying OpenSearch.

---

## AWS + CI/CD Scripts — Phase 3

### `scripts/phase3/00_prereqs_phase3.sh`

```bash
#!/bin/bash
set -euo pipefail
source scripts/lib/common.sh

log "Verifying Phase 2 complete..."
./scripts/validate_phase2.sh || {
  echo "ERROR: Phase 2 validation failed. Complete Phase 2 first."
  exit 1
}

log "Verifying KubeArmor baseline policies exist..."
[ -f "policies/kubearmor-baseline.yaml" ] || {
  echo "ERROR: policies/kubearmor-baseline.yaml not found."
  echo "Complete MANUAL STEP 7 first."
  exit 1
}

log "Verifying OpenSearch password in Vault..."
vault kv get secret/opensearch >/dev/null 2>&1 || {
  echo "ERROR: OpenSearch password not in Vault."
  echo "Complete MANUAL STEP 9 first."
  exit 1
}

log "Phase 3 prerequisites satisfied"
```

### `scripts/phase3/01_guardduty.sh`

Enables GuardDuty EKS Runtime Monitoring with automatic DaemonSet management.
Routes severity >= 7 findings to the existing SNS alert topic.

```bash
#!/bin/bash
set -euo pipefail
source scripts/lib/common.sh

REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log "Enabling GuardDuty detector..."
DETECTOR_ID=$(aws guardduty create-detector \
  --enable \
  --features '[{"Name":"EKS_AUDIT_LOGS","Status":"ENABLED"}]' \
  --query DetectorId --output text 2>/dev/null || \
  aws guardduty list-detectors --query 'DetectorIds[0]' --output text)

log "Enabling EKS Runtime Monitoring with addon management..."
aws guardduty update-detector \
  --detector-id $DETECTOR_ID \
  --features '[{
    "Name": "EKS_RUNTIME_MONITORING",
    "Status": "ENABLED",
    "AdditionalConfiguration": [{
      "Name": "EKS_ADDON_MANAGEMENT",
      "Status": "ENABLED"
    }]
  }]'

log "Routing critical findings (severity >= 7) to SNS..."
ALERT_TOPIC=$(vault kv get -field=alert_sns_topic secret/phase1-config 2>/dev/null || \
  aws sns list-topics \
    --query 'Topics[?contains(TopicArn,`security-alerts`)].TopicArn' \
    --output text)

aws events put-rule \
  --name guardduty-critical-findings \
  --event-pattern '{
    "source": ["aws.guardduty"],
    "detail": {"severity": [{"numeric": [">=", 7]}]}
  }' \
  --region $REGION 2>/dev/null || true

aws events put-targets \
  --rule guardduty-critical-findings \
  --targets "[{\"Id\":\"sns-alert\",\"Arn\":\"$ALERT_TOPIC\"}]" 2>/dev/null || true

vault kv patch secret/phase1-config guardduty_detector_id=$DETECTOR_ID || \
  vault kv put secret/phase1-config guardduty_detector_id=$DETECTOR_ID

log "GuardDuty EKS Runtime Monitoring enabled — findings routed to SNS"
```

### `scripts/phase3/02_cicd_workflows.sh`

Writes GitHub Actions workflow files for Garak red team and Checkov IaC scanning.

```bash
#!/bin/bash
set -euo pipefail
source scripts/lib/common.sh

mkdir -p .github/workflows

log "Writing Garak red team workflow..."
cat > .github/workflows/red-team.yml << 'WORKFLOW'
name: Red Team — Garak + arc_pi_taxonomy
on:
  push:
    paths:
      - 'agents/**'
      - 'services/security-gateway/**'
      - 'policies/**'
  pull_request:
    paths:
      - 'agents/**'
      - 'services/security-gateway/**'
      - 'policies/**'
  schedule:
    - cron: '0 2 * * *'

permissions:
  id-token: write
  contents: read

jobs:
  garak-red-team:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/github-actions-red-team
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Install Garak
        run: pip install garak

      - name: Run prompt injection + jailbreak probes
        run: |
          garak \
            --model_type rest \
            --model_name agentic-gateway \
            --probes garak.probes.injection.PromptInjection \
            --probes garak.probes.jailbreak.Dan \
            --probes garak.probes.leakage.SystemPromptLeak \
            --report_prefix reports/garak

      - name: Run arc_pi_taxonomy suite
        run: |
          git clone --depth 1 https://github.com/Arcanum-Sec/arc_pi_taxonomy
          python scripts/run_arc_pi_tests.py \
            --taxonomy arc_pi_taxonomy/ \
            --gateway-url ${{ secrets.GATEWAY_TEST_URL }} \
            --output reports/arc_pi_results.json

      - name: Fail on critical findings
        run: |
          python scripts/check_garak_results.py \
            --report reports/garak.report.jsonl \
            --fail-on critical,high

      - name: Upload reports
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: red-team-reports
          path: reports/
WORKFLOW

log "Writing Checkov IaC scanning workflow..."
cat > .github/workflows/checkov.yml << 'WORKFLOW'
name: IaC Security Scan — Checkov
on: [push, pull_request]

jobs:
  checkov:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Checkov — Helm charts
        uses: bridgecrewio/checkov-action@master
        with:
          directory: helmfile/
          framework: helm
          output_format: sarif
          output_file_path: reports/checkov-helm.sarif
          soft_fail: false

      - name: Checkov — Kubernetes manifests
        uses: bridgecrewio/checkov-action@master
        with:
          directory: services/
          framework: kubernetes
          output_format: sarif
          output_file_path: reports/checkov-k8s.sarif
          soft_fail: false

      - name: Upload SARIF to GitHub Security
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: reports/
WORKFLOW

git add .github/workflows/red-team.yml .github/workflows/checkov.yml
git commit -m "Add Garak red team and Checkov IaC CI/CD workflows"

log "CI/CD workflows committed"
```

### `scripts/phase3/03_github_oidc.sh`

Creates the AWS IAM OIDC provider and trust role for GitHub Actions.

```bash
#!/bin/bash
set -euo pipefail
source scripts/lib/common.sh

REGION=$(aws configure get region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO=${1:-"your-org/agentic-ai-security"}   # pass as arg: ./03_github_oidc.sh org/repo

log "Creating GitHub OIDC provider..."
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  2>/dev/null || log "OIDC provider already exists"

log "Creating GitHub Actions IAM role..."
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:$REPO:*"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name github-actions-red-team \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  2>/dev/null || log "Role already exists"

aws iam attach-role-policy \
  --role-name github-actions-red-team \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess

log "GitHub Actions OIDC configured for repo: $REPO"
```

---

## Helmfile — Phase 3

### `helmfile/phase3/helmfile.yaml.gotmpl`

```yaml
repositories:
  - name: kubearmor
    url: https://helm.kubearmor.io
  - name: opensearch
    url: https://opensearch-project.github.io/helm-charts

helmDefaults:
  wait: true
  timeout: 600
  createNamespace: true

releases:

  # ── KubeArmor ─────────────────────────────────────────────────────────────
  # Runtime security enforcement — blocks on policy violations, not just alerts.
  # Uses K8s CRDs for dynamic policy updates; OPAL controller drives changes
  # in response to OPA anomaly events.
  # Requires: policies/kubearmor-baseline.yaml reviewed and committed (MANUAL STEP 7)

  - name: kubearmor
    namespace: kubearmor-system
    chart: kubearmor/kubearmor
    values:
      - values/kubearmor.yaml

  - name: kubearmor-operator
    namespace: kubearmor-system
    chart: kubearmor/kubearmor-operator
    needs:
      - kubearmor-system/kubearmor
    values:
      - values/kubearmor-operator.yaml
    hooks:
      - events: ["postsync"]
        command: "bash"
        args: ["helmfile/phase3/hooks/kubearmor-apply-baseline.sh"]

  # ── KubeArmor OPAL Controller ─────────────────────────────────────────────
  # Watches OPA for runtime anomaly events (e.g. agent called unexpected process).
  # On anomaly: tightens the offending agent's KubeArmor CRD policy in real time.
  # Completes the OPAL → OPA → KubeArmor feedback loop.

  - name: kubearmor-controller
    namespace: kubearmor-system
    chart: ./charts/kubearmor-controller
    needs:
      - kubearmor-system/kubearmor-operator
    values:
      - values/kubearmor-controller.yaml

  # ── OpenSearch + Security Analytics ──────────────────────────────────────
  # Central SIEM for correlation rules across:
  # - Prompt injection events (LLM Guard)
  # - Biscuit scope violations (gateway)
  # - KubeArmor runtime blocks
  # - GuardDuty findings (via CloudWatch → OTel → OpenSearch)

  - name: opensearch
    namespace: observability
    chart: opensearch/opensearch
    needs:
      - kubearmor-system/kubearmor-operator
    values:
      - values/opensearch.yaml
    hooks:
      - events: ["postsync"]
        command: "bash"
        args: ["helmfile/phase3/hooks/opensearch-load-rules.sh"]

  - name: opensearch-dashboards
    namespace: observability
    chart: opensearch/opensearch-dashboards
    needs:
      - observability/opensearch
    values:
      - values/opensearch-dashboards.yaml

  # ── Policy Coverage Gap Analysis CronJob ─────────────────────────────────
  # Runs daily at 06:00. Compares:
  # - Tools registered in Consul vs tools covered by OPA Rego rules
  # - Agent types in registry vs Cedar policy coverage
  # - Agents active in last 24h vs agents with KubeArmor policies
  # Publishes gap report to SNS and OpenSearch.

  - name: gap-analysis
    namespace: infra
    chart: ./charts/gap-analysis
    needs:
      - observability/opensearch
    values:
      - values/gap-analysis.yaml

  # ── Posture Dashboard (Grafana upgrade) ───────────────────────────────────
  # Same release name as Phase 1 — Helmfile issues helm upgrade.
  # Adds OpenSearch datasource and provisions the posture dashboard ConfigMap.

  - name: grafana
    namespace: observability
    chart: grafana/grafana
    needs:
      - observability/opensearch
    values:
      - values/grafana.yaml
    hooks:
      - events: ["postsync"]
        command: "bash"
        args: ["helmfile/phase3/hooks/grafana-provision-dashboard.sh"]
```

---

## Key Values Files

### `helmfile/phase3/values/kubearmor.yaml`

```yaml
# Block mode: syscall violations are denied, not just logged.
# Discovery Engine generates candidate policies from observed behavior.
defaultFilePosture: block
defaultNetworkPosture: block
defaultCapabilitiesPosture: audit
kubearmorRelay:
  enabled: true
# SPIFFE identity awareness: KubeArmor reads SPIRE SVIDs to scope policies
# to specific workload identities rather than just pod labels.
spiffe:
  enabled: true
  socketPath: /run/spire/sockets/agent.sock
```

### `helmfile/phase3/values/opensearch.yaml`

```yaml
replicas: 3
persistence:
  size: 100Gi
extraEnvs:
  - name: OPENSEARCH_INITIAL_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: opensearch-credentials
        key: admin_password
plugins:
  enabled: true
  installList:
    - opensearch-security-analytics
```

### `helmfile/phase3/values/gap-analysis.yaml`

```yaml
schedule: "0 6 * * *"
env:
  CONSUL_URL: "http://consul.infra.svc.cluster.local:8500"
  OPA_URL: "http://opa.infra.svc.cluster.local:8181"
  OPENSEARCH_URL: "https://opensearch.observability.svc.cluster.local:9200"
serviceAccount:
  name: gap-analysis
```

### `helmfile/phase3/values/grafana.yaml`

```yaml
additionalDataSources:
  - name: OpenSearch
    type: grafana-opensearch-datasource
    url: https://opensearch.observability.svc.cluster.local:9200
    basicAuth: true
    basicAuthUser: admin
    secureJsonData:
      basicAuthPassword: "${OPENSEARCH_ADMIN_PASSWORD}"
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: posture
        folder: Security Posture
        type: file
        options:
          path: /var/lib/grafana/dashboards/posture
```

---

## Key Hook Scripts

### `helmfile/phase3/hooks/kubearmor-apply-baseline.sh`

Applies the human-reviewed KubeArmor baseline policies generated by the Discovery Engine. Also installs the `karmor` CLI for ongoing monitoring.

```bash
#!/bin/bash
set -euo pipefail

echo "Installing karmor CLI..."
curl -sfL https://raw.githubusercontent.com/kubearmor/KubeArmor/main/pkg/KubeArmor/karmor/install.sh \
  | sudo bash

echo "Applying reviewed baseline policies..."
[ -f "policies/kubearmor-baseline.yaml" ] || {
  echo "ERROR: policies/kubearmor-baseline.yaml not found — complete MANUAL STEP 7"
  exit 1
}
kubectl apply -f policies/kubearmor-baseline.yaml

echo "Verifying policies applied..."
COUNT=$(kubectl get kubearmorpolicies -A --no-headers 2>/dev/null | wc -l)
echo "KubeArmor policies applied: $COUNT"
[ "$COUNT" -gt 0 ] || { echo "ERROR: No KubeArmor policies found after apply"; exit 1; }

echo "KubeArmor baseline policies active"
```

### `helmfile/phase3/hooks/opensearch-load-rules.sh`

Creates a Kubernetes secret from Vault for OpenSearch credentials, then loads Security Analytics correlation rules.

```bash
#!/bin/bash
set -euo pipefail

OS_ADMIN_PASS=$(vault kv get -field=admin_password secret/opensearch)

kubectl create secret generic opensearch-credentials \
  -n observability \
  --from-literal=admin_password=$OS_ADMIN_PASS \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Waiting for OpenSearch cluster to be green..."
for i in $(seq 1 30); do
  STATUS=$(curl -sk -u "admin:$OS_ADMIN_PASS" \
    https://opensearch.observability.svc.cluster.local:9200/_cluster/health \
    | jq -r '.status' 2>/dev/null || echo "red")
  [ "$STATUS" = "green" ] && break
  echo "OpenSearch status: $STATUS — waiting... ($i/30)"
  sleep 10
done

echo "Loading Security Analytics correlation rules..."
BASE_URL="https://opensearch.observability.svc.cluster.local:9200/_plugins/_security_analytics/rules"
AUTH="-u admin:$OS_ADMIN_PASS -sk"

# Rule 1: Injection detected followed by tool call within 60 seconds
curl $AUTH -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Injection then tool call",
    "log_source": {"product": "agentic-gateway"},
    "description": "Prompt injection detected followed by a tool call within 60s from same agent",
    "detection": {
      "timeframe": 60,
      "condition": "injection_event and tool_call_event",
      "injection_event": {"scan_result": "unsafe"},
      "tool_call_event": {"event_type": "tool_call"}
    },
    "severity": "critical"
  }'

# Rule 2: Biscuit scope violation
curl $AUTH -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Biscuit scope violation",
    "log_source": {"product": "agentic-gateway"},
    "description": "Agent attempted to call a tool outside its Biscuit token scope",
    "detection": {
      "condition": "biscuit_violation",
      "biscuit_violation": {"verified": false, "reason": "scope_exceeded"}
    },
    "severity": "high"
  }'

# Rule 3: KubeArmor block correlated with GuardDuty finding on same node
curl $AUTH -X POST "$BASE_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Runtime anomaly cluster",
    "log_source": {"product": "kubearmor"},
    "description": "KubeArmor block and GuardDuty finding on the same node within 5 minutes",
    "detection": {
      "timeframe": 300,
      "condition": "kubearmor_block and guardduty_finding",
      "kubearmor_block": {"action": "Block"},
      "guardduty_finding": {"source": "aws.guardduty"}
    },
    "severity": "critical"
  }'

echo "Correlation rules loaded"
```

### `helmfile/phase3/hooks/grafana-provision-dashboard.sh`

Provisions the security posture dashboard into the running Grafana instance via ConfigMap.

```bash
#!/bin/bash
set -euo pipefail

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: posture-dashboard
  namespace: observability
  labels:
    grafana_dashboard: "1"
data:
  posture.json: |
    {
      "title": "Agentic AI Security Posture",
      "uid": "agentic-posture",
      "tags": ["security", "agentic-ai"],
      "panels": [
        {
          "title": "Active Agents",
          "type": "stat",
          "gridPos": {"x":0,"y":0,"w":4,"h":4},
          "targets": [{"expr": "count(consul_kv_get{key=~\"agents/.*\", status=\"active\"})"}]
        },
        {
          "title": "Policy Coverage %",
          "type": "gauge",
          "gridPos": {"x":4,"y":0,"w":4,"h":4},
          "fieldConfig": {"defaults": {"min": 0, "max": 100, "thresholds": {"steps": [
            {"value": 0, "color": "red"},
            {"value": 80, "color": "yellow"},
            {"value": 95, "color": "green"}
          ]}}},
          "targets": [{"datasource": "OpenSearch", "query": "gap_analysis.coverage_pct"}]
        },
        {
          "title": "Injection Attempts — 24h",
          "type": "timeseries",
          "gridPos": {"x":0,"y":4,"w":12,"h":6},
          "targets": [{"expr": "sum(rate(gateway_scan_unsafe_total[5m]))"}]
        },
        {
          "title": "OPA Deny Rate",
          "type": "timeseries",
          "gridPos": {"x":12,"y":4,"w":12,"h":6},
          "targets": [{"expr": "rate(opa_decision_deny_total[5m])"}]
        },
        {
          "title": "Biscuit Violations — 24h",
          "type": "stat",
          "gridPos": {"x":0,"y":10,"w":4,"h":4},
          "targets": [{"expr": "increase(gateway_biscuit_violation_total[24h])"}]
        },
        {
          "title": "HITL Triggers — 24h",
          "type": "stat",
          "gridPos": {"x":4,"y":10,"w":4,"h":4},
          "targets": [{"expr": "increase(ciba_approval_request_total[24h])"}]
        },
        {
          "title": "KubeArmor Blocks — 24h",
          "type": "stat",
          "gridPos": {"x":8,"y":10,"w":4,"h":4},
          "targets": [{"datasource": "OpenSearch", "query": "kubearmor.action:Block"}]
        },
        {
          "title": "GuardDuty Findings",
          "type": "table",
          "gridPos": {"x":0,"y":14,"w":24,"h":6},
          "targets": [{"datasource": "OpenSearch", "query": "source:aws.guardduty"}]
        },
        {
          "title": "Cedar Policy Rejections",
          "type": "timeseries",
          "gridPos": {"x":0,"y":20,"w":12,"h":6},
          "targets": [{"expr": "rate(cedar_policy_deny_total[5m])"}]
        },
        {
          "title": "Tool Hash Mismatches",
          "type": "stat",
          "gridPos": {"x":12,"y":20,"w":4,"h":4},
          "targets": [{"expr": "sum(consul_kv_get{key=~\"tools/.*\", status=\"hash_mismatch\"})"}]
        }
      ]
    }
EOF

kubectl rollout restart deployment grafana -n observability
kubectl rollout status deployment grafana -n observability

echo "Posture dashboard provisioned in Grafana"
```

---

## Validation

### `scripts/validate_phase3.sh`

```bash
#!/bin/bash
set -euo pipefail
PASS=0; FAIL=0

check() {
  if eval "$2" >/dev/null 2>&1; then echo "PASS: $1"; ((PASS++))
  else echo "FAIL: $1"; ((FAIL++)); fi
}

check "GuardDuty EKS Runtime Monitoring enabled" \
  "DETECTOR=\$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text) && \
   aws guardduty get-detector --detector-id \$DETECTOR \
   | jq -r '.Features[] | select(.Name==\"EKS_RUNTIME_MONITORING\") | .Status' \
   | grep -q ENABLED"

check "KubeArmor baseline policies applied" \
  "kubectl get kubearmorpolicies -A --no-headers 2>/dev/null | wc -l | grep -v '^0'"

check "KubeArmor blocking shell spawn in agents namespace" \
  "kubectl exec -n agents deploy/web-search-agent -- /bin/bash -c 'echo test' 2>&1 \
   | grep -qi 'Operation not permitted\|Permission denied\|blocked'"

check "KubeArmor OPAL controller running" \
  "kubectl get deploy kubearmor-policy-controller -n kubearmor-system \
   --no-headers | awk '{print \$4}' | grep -v '^0'"

check "OpenSearch cluster healthy" \
  "OS_PASS=\$(vault kv get -field=admin_password secret/opensearch) && \
   curl -sk -u admin:\$OS_PASS \
   https://opensearch.observability.svc.cluster.local:9200/_cluster/health \
   | jq -r '.status' | grep -qE 'green|yellow'"

check "OpenSearch receiving audit events" \
  "OS_PASS=\$(vault kv get -field=admin_password secret/opensearch) && \
   curl -sk -u admin:\$OS_PASS \
   https://opensearch.observability.svc.cluster.local:9200/agentic-audit/_count \
   | jq -r '.count' | grep -v '^0'"

check "Correlation rules loaded" \
  "OS_PASS=\$(vault kv get -field=admin_password secret/opensearch) && \
   curl -sk -u admin:\$OS_PASS \
   https://opensearch.observability.svc.cluster.local:9200/_plugins/_security_analytics/rules/_search \
   | jq -r '.hits.total.value' | grep -v '^0'"

check "Garak workflow in repo" \
  "[ -f .github/workflows/red-team.yml ]"

check "Checkov workflow in repo" \
  "[ -f .github/workflows/checkov.yml ]"

check "Gap analysis CronJob scheduled" \
  "kubectl get cronjob policy-gap-analysis -n infra --no-headers \
   | grep -q policy-gap-analysis"

check "Posture dashboard ConfigMap present" \
  "kubectl get configmap posture-dashboard -n observability --no-headers \
   | grep -q posture-dashboard"

echo
echo "Phase 3: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && echo "✓ Phase 3 COMPLETE — Full stack operational" || exit 1
```

---

## Full Delivery Summary

| Capability | Phase 1 | Phase 2 | Phase 3 | Manual Step |
|---|---|---|---|---|
| Workload identity (SPIRE + k8s_sat) | ✓ | | | |
| Network zero trust (Istio strict mTLS) | ✓ | | | |
| Baseline policy engine (OPA + Rego) | ✓ | | | |
| Agent + Tool registry (Consul KV) | ✓ | | | |
| Secrets management (Vault + KMS) | ✓ | | MS3 (recovery keys) | |
| Auth + CIBA SMS (Keycloak + SNS) | ✓ | | MS1 (aws configure), MS2 (ACM cert) | |
| Audit trail (OTel + Loki + Grafana) | ✓ | | | |
| Dynamic policy sync (OPAL → OPA) | | ✓ | | |
| Dynamic policy engine (Cedar) | | ✓ | | |
| Self-attenuating delegation (Biscuits) | | ✓ | | |
| Local LLM judge + policy (Ollama) | | ✓ | | |
| Intent-aware tool catalog | | ✓ | | |
| Prompt injection filter (LLM Guard) | | ✓ | | |
| Duo Mobile CIBA push | | ✓ | MS5 (Duo console) | |
| Tool hash integrity (CronJob) | | ✓ | | |
| LiteLLM model proxy | | ✓ | | |
| Runtime enforcement (KubeArmor CRDs) | | | ✓ | MS7 (policy review) |
| Managed runtime detection (GuardDuty) | | | ✓ | |
| OPAL → KubeArmor feedback loop | | | ✓ | |
| Automated red teaming (Garak) | | | ✓ | MS8 (GitHub secrets) |
| SIEM + correlation (OpenSearch) | | | ✓ | MS9 (admin password) |
| IaC scanning (Checkov CI/CD) | | | ✓ | |
| Daily policy gap analysis | | | ✓ | |
| Security posture dashboard (Grafana) | | | ✓ | |

**Manual steps summary:**

| ID | Step | When |
|---|---|---|
| MS1 | `aws configure` | Before Phase 1 |
| MS2 | ACM certificate DNS validation | Phase 1 (HTTPS for Keycloak + portal) |
| MS3 | Vault recovery key storage (offline) | Phase 1 first init |
| MS4 | Duo account creation | Phase 1 (prep for Phase 2) |
| MS5 | Duo admin console — create Auth API application | Before Phase 2 |
| MS6 | KubeArmor discovery — run `karmor discover` after 48h | After Phase 2 running |
| MS7 | Review + commit `policies/kubearmor-baseline.yaml` | Before Phase 3 |
| MS8 | GitHub Actions secrets in repo settings | Before Phase 3 |
| MS9 | OpenSearch admin password → Vault | Before Phase 3 |
