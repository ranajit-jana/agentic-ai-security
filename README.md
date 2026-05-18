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
| Audit logging | OTel Collector → Loki → Grafana |
| Container registry | AWS ECR (immutable tags, scan on push) |
| IaC | AWS CLI + eksctl (infra) · Helmfile (K8s workloads) |

---

## Repository Layout

```
.
├── scripts/
│   ├── lib/common.sh            # Shared helper functions
│   ├── 01_aws_infra.sh          # KMS · ECR · SNS · IAM roles
│   ├── 02_eks_cluster.sh        # EKS cluster · node groups · EBS CSI
│   ├── 03_kubeconfig.sh         # aws eks update-kubeconfig
│   ├── 04_helmfile_deploy.sh    # Install helm/helmfile + deploy all releases
│   ├── destroy.sh               # Tear down ALB → LBC → LBC IAM → EKS cluster (in order)
│   └── validate_phase1.sh       # Automated Phase 1 checks (23 checks)
│
├── helmfile/
│   └── phase1/
│       ├── helmfile.yaml.gotmpl # All Phase 1 releases with ordering + hooks
│       ├── values/              # Per-chart values
│       ├── hooks/               # Post-deploy configuration scripts
│       └── manifests/           # Raw K8s manifests
│
├── charts/
│   ├── ciba-acp/                # Custom CIBA Authentication Channel Provider
│   ├── keycloak/                # Keycloak + PostgreSQL
│   ├── redis/                   # Redis for rate limiting
│   ├── security-gateway/        # Custom agent gateway (FastAPI + Envoy)
│   └── agents/                  # Agent workload deployments
│
├── policies/
│   └── baseline/
│       └── agentic.rego         # OPA baseline policy — permanent floor rules
│
├── docs/
│   └── vault.md                 # Vault operations guide
│
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

### Phase 1 — Core Security Foundation

Phase 1 deploys: Istio · Istio Ingress Gateway · SPIRE · Consul · Vault · Keycloak · CIBA ACP · OPA · Redis · Security Gateway · OTel · Loki · Grafana · Agents

```bash
# Step 0 — configure AWS credentials
aws configure
# Enter: Access Key ID, Secret Access Key, region (ap-south-1), output (json)
aws sts get-caller-identity   # verify

# Step 1 — AWS resources (KMS, ECR, SNS, IAM roles)
bash scripts/01_aws_infra.sh

# Step 2 — EKS cluster + node groups + EBS CSI driver (~15 min)
bash scripts/02_eks_cluster.sh

# Step 3 — Point kubectl at the new cluster
bash scripts/03_kubeconfig.sh

# Step 4 — Deploy all Phase 1 workloads (~20 min)
bash scripts/04_helmfile_deploy.sh

# Step 5 — Validate (should be 23/23)
bash scripts/validate_phase1.sh
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
| `https://grafana.rj-lab.click` | Grafana dashboards |

Internal-only services (Vault, Consul) remain accessible within the cluster via `.firm.internal` hostnames and are not exposed publicly.

```bash
# Verify ALB is provisioned
kubectl get ingress platform-public-alb -n istio-system

# Verify DNS
dig +short auth.rj-lab.click
dig +short grafana.rj-lab.click
```

### Phase 2 — Hardening *(coming next)*

Adds: Ollama (LLM judge + embeddings) · OPAL · Cedar dynamic policies · Biscuit keys · LLM Guard · Intent-Aware Tool Catalog · Duo Mobile CIBA push · Tool hash verifier

```bash
bash scripts/phase2/00_prereqs_phase2.sh
bash scripts/phase2/01_gpu_nodegroup.sh
helmfile sync -f helmfile/phase2/helmfile.yaml.gotmpl
bash scripts/validate_phase2.sh
```

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

### Node Groups

| Group | Type | Count | Workloads |
|---|---|---|---|
| `system` | `t3.medium` | 2 | CoreDNS · Consul · SPIRE · Istio · Vault |
| `application` | `t3.large` | 2–4 | Agents · Keycloak · OPA · Gateway |
| `observability` | `t3.medium` | 1–2 | OTel · Loki · Grafana |
| `gpu` *(Phase 2)* | `g4dn.xlarge` | 1–2 | Ollama (LLM judge + embeddings) |

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
| 2 | Before Phase 1 deploy | Attach `OIDCProviderAccess` inline policy to `aws-dev` IAM user |
| 3 | During Phase 1 deploy | Save Vault recovery keys + root token to password manager |
| 4 | Before Phase 2 | Create Duo Security app, store creds in Vault |
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

- [Vault operations guide](docs/vault.md)
- [Implementation decisions](implementation.md)
- [Phase 1 plan](plan_phase1.md)
- [Phase 2 plan](plan_phase2.md)
- [Phase 3 plan](plan_phase3.md)
- [SPIFFE/SPIRE](https://spiffe.io)
- [Cedar Policy Language](https://github.com/cedar-policy/cedar)
- [Biscuit Auth](https://github.com/biscuit-auth/biscuit)
- [Open Policy Agent](https://www.openpolicyagent.org)
- [Keycloak CIBA](https://www.keycloak.org/docs/latest/server_admin/#_ciba)
