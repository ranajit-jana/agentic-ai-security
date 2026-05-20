# Agentic AI Security Platform

A production-grade security infrastructure for agentic AI systems, deployed on AWS EKS. Implements zero-trust identity, dynamic least-privilege authorization, CIBA-based human-in-the-loop approvals, prompt injection defences, and full audit lineage across all agent tool calls.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Human User  ──OIDC/CIBA──►  Keycloak  ◄──ACP──  CIBA ACP     │
└─────────────────────────────┬───────────────────────────────────┘
                              │ JWT / CIBA token
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Orchestrator Agent  (SPIFFE SVID + Biscuit delegation)        │
│     │                                                           │
│     ├──► Web Search Agent                                       │
│     ├──► Internal Data Agent                                    │
│     ├──► Report Generation Agent                                │
│     └──► Email Agent                                            │
└─────────────────────────────┬───────────────────────────────────┘
                              │ Every tool call
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Security Gateway                                               │
│   1. mTLS / SPIFFE identity verify                              │
│   2. Biscuit scope check                                        │
│   3. OPA baseline Rego policy                                   │
│   4. Cedar dynamic task policy                                  │
│   5. LLM-as-Judge (intent match)                                │
│   6. Tool registry hash verify (Consul)                         │
│   7. Rate limit (Redis)                                         │
│   8. HITL trigger (risk score > threshold)                      │
└─────────────────────────────┬───────────────────────────────────┘
                              │ mTLS (SPIFFE X.509)
                              ▼
                        MCP Tool Servers
```

---

## Technology Stack

| Layer | Technology |
|---|---|
| Platform | AWS EKS 1.35 (ap-south-1), private VPC subnets |
| Service mesh | Istio 1.29 — mTLS enforced; certs issued by SPIRE |
| Ingress | AWS ALB (AWS Load Balancer Controller) → Istio Ingress Gateway — TLS terminated at ALB using ACM wildcard cert |
| Public DNS | Route 53 — `*.rj-lab.click` ALIAS records auto-wired to ALB on deploy |
| TLS certificate | ACM wildcard `*.rj-lab.click` — DNS-validated via Route 53 |
| Workload identity | SPIFFE / SPIRE — `k8s_sat` attestor, SPIFFE CSI driver |
| IDP + CIBA | Keycloak 21 (self-hosted) + AWS SNS for approval delivery |
| Delegation tokens | Biscuits (Ed25519, signing key = SPIRE SVID) |
| Baseline policy | OPA + kube-mgmt — Rego, ConfigMap-synced |
| Dynamic policy | Cedar (Apache 2.0) — LLM-generated, formally verified, task-scoped |
| Service registry | Consul KV — agent registry + tool registry |
| Secrets | HashiCorp Vault (HA Raft 3-node) + AWS KMS auto-unseal |
| Gateway | FastAPI orchestrator + Envoy + LiteLLM |
| Rate limiting | Redis |
| Tracing | OpenTelemetry → Loki → Grafana |
| Audit logging | OTel Collector → Loki → Grafana (WARNING+ only) |
| Log level | WARNING and above across all services — INFO suppressed at source |
| Container registry | AWS ECR (immutable tags, scan on push) |
| IaC | AWS CLI + eksctl (infra) · Helmfile (K8s workloads) |

---

## Repository Layout

```
.
├── scripts/
│   ├── lib/common.sh            # Shared helper functions
│   ├── 01_aws_infra.sh          # KMS · ECR · SNS · IAM roles (run once)
│   ├── 02_eks_cluster.sh        # EKS cluster · 4 node groups · EBS CSI
│   ├── 03_kubeconfig.sh         # aws eks update-kubeconfig
│   ├── 04_helmfile_deploy.sh    # Install helm/helmfile + deploy all releases
│   ├── destroy.sh               # Tear down ALB → LBC → LBC IAM → EKS cluster
│   └── validate.sh              # Automated checks — all Phase 1 + Phase 2 checks
│
├── helmfile/
│   └── phase1/
│       ├── helmfile.yaml.gotmpl # All releases (Phase 1 + 2) with ordering + hooks
│       ├── values/              # Per-chart values files
│       ├── hooks/               # Post/pre-deploy configuration scripts
│       └── manifests/           # Raw K8s manifests (PeerAuthentication, Ingress…)
│
├── charts/
│   ├── ciba-acp/                # CIBA Authentication Channel Provider + Duo push
│   ├── hash-verifier/           # Tool hash verifier CronJob
│   ├── injection-signals/       # arc_pi_taxonomy embedding index builder
│   ├── keycloak/                # Keycloak + PostgreSQL (no Bitnami)
│   ├── redis/                   # Redis for rate limiting (no Bitnami)
│   ├── security-gateway/        # Agent gateway (FastAPI + Envoy + Cedar + LLM Guard)
│   ├── tool-catalog/            # Intent-aware tool catalog service
│   └── agents/                  # Agent workload deployments
│
├── policies/
│   └── baseline/
│       └── agentic.rego         # OPA baseline policy — permanent floor rules
│
├── docs/
│   ├── vault.md                 # Vault operations guide
│   └── phase2.md                # Phase 2 component guide (what + why)
│
├── setup.txt                    # Operator runbook (deploy order, manual steps)
├── implementation.md            # Technology decision record
├── plan_phase1.md               # Phase 1 detailed plan
├── plan_phase2.md               # Phase 2 detailed plan
└── plan_phase3.md               # Phase 3 detailed plan
```

---

## Deployment

### Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| `aws` CLI | ≥ 2.x | AWS resource provisioning |
| `eksctl` | ≥ 0.175 | EKS cluster management + OIDC provider registration |
| `kubectl` | ≥ 1.29 | Cluster interaction |
| `jq` | any | JSON parsing in scripts |
| `python3` | ≥ 3.8 | Used in hook scripts |
| `dig` | any | Verify DNS propagation after deploy |

> `helm` and `helmfile` are installed automatically by `04_helmfile_deploy.sh`.

#### IAM permissions required for `aws-dev`

The following inline policies must be attached to the deploying IAM user in addition to `PowerUserAccess`:

| Policy name | Actions |
|---|---|
| `TerraformIAMAccess` | `iam:CreateRole`, `iam:DeleteRole`, `iam:AttachRolePolicy`, `iam:DetachRolePolicy`, `iam:CreatePolicy`, `iam:DeletePolicy`, `iam:GetRole`, `iam:PassRole` |
| `OIDCProviderAccess` | `iam:CreateOpenIDConnectProvider`, `iam:GetOpenIDConnectProvider`, `iam:ListOpenIDConnectProviders`, `iam:TagOpenIDConnectProvider`, `iam:DeleteOpenIDConnectProvider` |

### Deploy — Combined Phase 1 + Phase 2

Deploys everything in one run: Istio · SPIRE · Consul · Vault · Keycloak · OPA · Redis · Security Gateway · OTel · Loki · Grafana · Ollama (judge/policy/embed) · OPAL · Tool Catalog · Cedar/Biscuit/LLM Guard · Injection Signals · CIBA ACP + Duo · Hash Verifier · LiteLLM · Agents

**First time only:**
```bash
# Step 0 — configure AWS credentials
aws configure
aws sts get-caller-identity   # verify

# Step 1 — AWS resources (KMS, ECR, SNS, IAM roles) — run ONCE, persists forever
bash scripts/01_aws_infra.sh

# Step 2 — EKS cluster + 4 node groups (~15 min)
bash scripts/02_eks_cluster.sh

# Step 3 — Point kubectl at the new cluster
bash scripts/03_kubeconfig.sh

# Step 3a — Store Duo credentials in Vault (required for CIBA push)
#   kubectl port-forward svc/vault -n infra 8200:8200
#   vault kv put secret/duo ikey=<> skey=<> host=<>
#   (see setup.txt → DUO CREDENTIALS for full steps)

# Step 4 — Deploy all workloads + wire DNS (~35 min; Ollama pulls ~4.7 GB first run)
bash scripts/04_helmfile_deploy.sh

# Step 5 — Validate all checks
bash scripts/validate.sh
```

**Every subsequent rebuild (skip step 1):**
```bash
bash scripts/02_eks_cluster.sh      # recreate cluster + OIDC provider
bash scripts/03_kubeconfig.sh
bash scripts/04_helmfile_deploy.sh  # deploys everything + wires Route 53 → ALB
bash scripts/validate.sh
```

### Vault Init — Required Human Step

During `04_helmfile_deploy.sh`, the `vault-init.sh` hook will pause and print:

```
>>> Press Enter ONLY after you have saved ALL 5 recovery keys and the root token:
```

The keys are written to three places simultaneously before the pause:
- `~/vault-init-keys-<timestamp>.txt` (chmod 600)
- Printed to the console
- Kubernetes Secret `vault-init-keys` in the `infra` namespace

**Save all 5 recovery keys + root token to a password manager, then press Enter.**

After saving:
```bash
kubectl delete secret vault-init-keys -n infra
rm ~/vault-init-keys-*.txt
```

See [docs/vault.md](docs/vault.md) for full Vault operations guide.

### Accessing Services After Deploy

Public services are exposed over HTTPS via an AWS ALB with the ACM wildcard cert for `*.rj-lab.click`. Route 53 ALIAS records are created automatically at the end of `04_helmfile_deploy.sh`.

| URL | Service |
|---|---|
| `https://auth.rj-lab.click` | Keycloak (OIDC / CIBA auth) |
| `https://gateway.rj-lab.click` | Security Gateway API |
| `https://keycloak.rj-lab.click` | Keycloak admin console |
| `https://grafana.rj-lab.click` | Grafana dashboards (WARNING/ERROR logs only) |

Internal-only services (Vault, Consul) remain accessible within the cluster via `.firm.internal` hostnames and are not exposed publicly.

#### Grafana dashboards

Three dashboards are pre-loaded under the **Agentic Security** folder:

| Dashboard | Content |
|---|---|
| **Security Gateway** | All decisions · Denied requests · HITL triggers |
| **Agent Activity** | Per-agent logs — orchestrator, web-search, internal-data, email, report |
| **Logs / App** | Community Loki explorer — browse any app's logs |

All dashboard queries are filtered to `WARNING` and above. Default credentials: `admin` / see Vault (`secret/grafana/admin`). **Change the password before exposing to the internet.**

```bash
# Verify ALB is provisioned
kubectl get ingress platform-public-alb -n istio-system

# Verify DNS
dig +short auth.rj-lab.click
dig +short grafana.rj-lab.click
```

### Nightly Destroy / Morning Rebuild

The EKS cluster (~$330/month if left running) should be destroyed when not in use. Resources that cost under $2/month (KMS, ECR, ACM, Route 53, SNS, IAM, EFS) are kept permanently — `01_aws_infra.sh` only needs to run once ever.

**Evening (~2 min):**
```bash
bash scripts/destroy.sh
# Removes: ALB → LBC → EKS cluster + NAT gateway + VPC
# Keeps:   EFS ollama-models (models persist — no re-download on next rebuild)
```

**Morning (~20 min — Ollama skips model download, EFS already has models):**
```bash
bash scripts/02_eks_cluster.sh      # recreate cluster + EFS CSI driver + mount EFS PVC
bash scripts/03_kubeconfig.sh       # point kubectl at it
bash scripts/04_helmfile_deploy.sh  # deploy Phase 1 + Phase 2 + wire DNS automatically
bash scripts/validate.sh
```

> `01_aws_infra.sh` is **not needed** on subsequent rebuilds — KMS, ECR, SNS, and IAM roles persist.
>
> The IAM OIDC provider is recreated automatically by `02_eks_cluster.sh` on every rebuild — each new cluster gets a fresh OIDC issuer ID so this must run each time.

**What costs >$2/month (deleted nightly):**

| Resource | Per month |
|---|---|
| EC2 nodes — spot (3×t3.medium + 2×t3.large + 1×t3.medium + 2×m5.xlarge) | ~$75 |
| EKS control plane | ~$72 |
| NAT Gateway | ~$14 |
| ALB | ~$7 |

**What stays (free or <$2/month):**

| Resource | Per month |
|---|---|
| EFS — `ollama-models` (llama3.1:8b + nomic-embed-text, ~5 GB) | ~$1.50 |
| KMS key | $1.00 |
| Route 53 hosted zone | $0.50 |
| ECR images | ~$0.30 |
| ACM wildcard cert | $0 |
| SNS topics | $0 |

---

### Phase 2 — Now Merged Into Phase 1 Deployment

Phase 2 releases are included in `helmfile/phase1/helmfile.yaml.gotmpl` and deploy automatically with `04_helmfile_deploy.sh`. No separate deploy step required.

**Before first deploy, store Duo credentials in Vault** (Duo push won't work without them):
```bash
# Port-forward to Vault (after vault-init hook completes)
kubectl port-forward svc/vault -n infra 8200:8200
export VAULT_ADDR=http://127.0.0.1:8200
vault login <root-token>
vault kv put secret/duo ikey=<Integration-Key> skey=<Secret-Key> host=<API-Hostname>
```

The `sync-duo-secret.sh` presync hook reads Vault automatically on every deploy and creates the `duo-credentials` Kubernetes secret. If Duo is not yet in Vault, ciba-acp starts with an empty secret (push disabled, no crash).

**Phase 2 releases deployed automatically:**

| Release | Chart | Purpose |
|---|---|---|
| `ollama-judge` | `ollama/ollama` | LLM Judge — validates tool call intent alignment |
| `ollama-policy` | `ollama/ollama` | Policy LLM — Cedar policy generation and validation |
| `ollama-embed` | `ollama/ollama` | Embedding model — semantic prompt injection detection |
| `opal` | `permitio/opal` | Real-time policy sync: Consul → OPA |
| `tool-catalog` | `./charts/tool-catalog` | Intent-aware tool filtering (replaces raw MCP tools/list) |
| `security-gateway` | `./charts/security-gateway` | Upgraded with Cedar + Biscuit + LLM Guard |
| `injection-signals` | `./charts/injection-signals` | Builds arc_pi_taxonomy embedding index for injection detection |
| `ciba-acp` | `./charts/ciba-acp` | Upgraded with Duo Mobile push |
| `hash-verifier` | `./charts/hash-verifier` | CronJob — verifies tool OCI digest + MCP hash every 60s |
| `litellm` | `./charts/litellm` | Unified model gateway — routes to Claude or local Ollama (stateless, no DB) |

> Ollama runs on the `inference` nodegroup (`m5.xlarge`, 16 GB RAM, CPU-only). `llama3.1:8b` requires ~6 GB RAM; adequate for background policy checks (~10 tok/s). All three instances share one EFS volume (`ollama-models-shared`) — models download once on first deploy and persist across cluster rebuilds.

See [docs/phase2.md](docs/phase2.md) for a detailed explanation of each component.

### Phase 3 — Threat Management *(coming next)*

Adds: KubeArmor · AWS GuardDuty EKS runtime · OpenSearch Security Analytics · Garak red teaming CI · Posture gap analysis dashboard

```bash
bash scripts/phase3/00_prereqs_phase3.sh
bash scripts/phase3/01_guardduty.sh
helmfile sync -f helmfile/phase3/helmfile.yaml.gotmpl
bash scripts/validate_phase3.sh
```

---

## AWS Environment

| Resource | Value |
|---|---|
| Region | `ap-south-1` |
| EKS cluster | `agentic-security` |
| Kubernetes version | `1.35` |
| Vault KMS key ID | `09bab559-b3ab-45f4-a437-d3b32aed7fbc` |
| Vault KMS key alias | `alias/vault-unseal` |
| SNS topic — CIBA approvals | `ciba-approvals` |
| SNS topic — security alerts | `security-alerts` |
| Public domain | `rj-lab.click` |
| Route 53 hosted zone | `Z02035941A90NEJDXI763` |
| ACM certificate | `*.rj-lab.click` (wildcard, DNS-validated) |
| ALB Ingress | `platform-public-alb` in `istio-system` |
| LBC IAM role | `AmazonEKSLoadBalancerControllerRole` |
| EFS filesystem | `ollama-models` — shared Ollama model cache (survives cluster teardown) |

### Node Groups

All nodegroups run **spot instances** (~70% cheaper than on-demand). Multiple instance types per group improve spot availability.

| Group | Types (spot) | Count | Workloads |
|---|---|---|---|
| `system` | `t3.medium` · `t3a.medium` · `t3.large` | 3 | CoreDNS · Consul · SPIRE · Istio · Vault · Keycloak · OPA · Gateway · OPAL · Tool Catalog |
| `application` | `t3.large` · `t3a.large` · `m5.large` | 2–4 | Agents · LiteLLM |
| `observability` | `t3.medium` · `t3a.medium` | 1–2 | OTel · Loki · Grafana |
| `inference` | `m5.xlarge` · `m5a.xlarge` · `m5.2xlarge` | 1–2 | Ollama judge · Ollama policy · Ollama embed — CPU inference, ~10 tok/s (adequate for background policy checks) |

---

## Key Security Flows

### Agent Tool Call (every request)

```
Agent  →  Gateway
           ├─ 1. Verify SPIFFE X.509 (mTLS)
           ├─ 2. Verify Biscuit delegation scope
           ├─ 3. OPA: baseline Rego allow?      → DENY → block
           ├─ 4. Cedar: task policy allow?       → DENY → block
           ├─ 5. LLM Judge: intent match?        → NO   → block
           ├─ 6. Consul: tool status == active?  → NO   → block
           ├─ 7. Redis: rate limit ok?            → NO   → block
           └─ 8. Risk score > threshold?         → YES  → HITL pause
                                                 → NO   → dispatch via mTLS
```

### CIBA Human Approval

```
Agent initiates CIBA → Keycloak → CIBA ACP → AWS SNS → SMS to user
                                                  ↓
User taps approval link → Keycloak issues token → Agent polls → proceeds
```

---

## Manual Steps Summary

| Step | When | What |
|---|---|---|
| 1 | Before any script | `aws configure` |
| 2 | Before first deploy | Attach `OIDCProviderAccess` inline policy to `aws-dev` IAM user |
| 3 | During deploy | Save Vault recovery keys + root token to password manager |
| 4 | Before or after deploy | Create Duo Security app, store creds in Vault (`secret/duo`) |
| 5 | Before Phase 3 | Review KubeArmor discovery policies |

---

## Ingress Architecture

Traffic flows from the public internet through two layers:

```
Browser (HTTPS)
  │
  ▼
AWS ALB  ──  terminates TLS with ACM wildcard cert (*.rj-lab.click)
  │          HTTP/80 forwarded to Istio gateway pods (target-type: ip)
  ▼
Istio IngressGateway  ──  routes by Host header via VirtualServices
  │
  ▼
Backend services (security-gateway · keycloak · grafana)
  │   (mTLS inside the mesh)
  ▼
Istio sidecar proxies
```

**Why ALB in front of Istio (not NLB)?**

ACM certificates cannot be exported — AWS never releases the private key. Istio's Gateway needs the raw key material to terminate TLS itself, so it cannot use ACM directly. The solution is to terminate TLS at the ALB (which can use ACM natively) and forward plain HTTP to the Istio gateway, which then handles all Layer 7 routing internally.

This means two systems handle different concerns:

| Layer | Handled by |
|---|---|
| Public TLS termination | ALB + ACM |
| Host-based HTTP routing | Istio VirtualServices |
| Service-to-service mTLS | Istio + SPIRE |

The AWS Load Balancer Controller (`aws-load-balancer-controller` in `kube-system`) manages the ALB lifecycle from the `platform-public-alb` Ingress resource in `istio-system`.

---

## References

- [Final architecture — all phases](docs/phase3.md)
- [Observability & correlation options](docs/observability.md)
- [Vault operations guide](docs/vault.md)
- [Phase 2 component guide](docs/phase2.md)
- [Implementation decisions](implementation.md)
- [Phase 1 plan](plan_phase1.md)
- [Phase 2 plan](plan_phase2.md)
- [Phase 3 plan](plan_phase3.md)
- [SPIFFE/SPIRE](https://spiffe.io)
- [Cedar Policy Language](https://github.com/cedar-policy/cedar)
- [Biscuit Auth](https://github.com/biscuit-auth/biscuit)
- [Open Policy Agent](https://www.openpolicyagent.org)
- [Keycloak CIBA](https://www.keycloak.org/docs/latest/server_admin/#_ciba)
