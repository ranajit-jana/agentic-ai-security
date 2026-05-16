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
| Service mesh | Istio 1.20 — mTLS enforced; certs issued by SPIRE |
| Workload identity | SPIFFE / SPIRE — `k8s_sat` attestor, cloud-agnostic |
| IDP + CIBA | Keycloak 21 (self-hosted) + AWS SNS for approval delivery |
| Delegation tokens | Biscuits (Ed25519, signing key = SPIRE SVID) |
| Baseline policy | OPA + OPAL — human-written Rego, permanent floor rules |
| Dynamic policy | Cedar (Apache 2.0) — LLM-generated, formally verified, task-scoped |
| Service registry | Consul KV — agent registry + tool registry |
| Secrets | HashiCorp Vault (HA Raft, 3 replicas) + AWS KMS auto-unseal |
| Gateway | FastAPI orchestrator + Envoy + LiteLLM |
| Rate limiting | Envoy + Redis (ephemeral, no persistence needed) |
| Tracing | OpenTelemetry → Jaeger |
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
│   ├── validate_phase1.sh       # Automated Phase 1 checks
│   ├── phase2/                  # Phase 2 scripts (GPU node group, prereqs)
│   └── phase3/                  # Phase 3 scripts (GuardDuty, CI/CD OIDC)
│
├── helmfile/
│   ├── phase1/
│   │   ├── helmfile.yaml        # All Phase 1 releases with ordering + hooks
│   │   ├── values/              # Per-chart values (region/account already set)
│   │   ├── hooks/               # Post-deploy configuration scripts
│   │   └── manifests/           # Raw K8s manifests (PeerAuthentication, etc.)
│   ├── phase2/
│   └── phase3/
│
├── charts/
│   ├── ciba-acp/                # Custom CIBA Authentication Channel Provider
│   ├── security-gateway/        # Custom agent gateway (FastAPI + Envoy)
│   └── agents/                  # Agent workload deployments
│
├── services/
│   ├── ciba-acp/                # FastAPI app source + Dockerfile
│   └── security-gateway/        # FastAPI app source + Dockerfile
│
├── policies/
│   └── baseline/                # OPA Rego — permanent floor rules
│
├── implementation.md            # Full technology decision record
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
| `eksctl` | ≥ 0.175 | EKS cluster management |
| `kubectl` | ≥ 1.29 | Cluster interaction |
| `helm` | ≥ 3.14 | Chart rendering |
| `helmfile` | ≥ 0.162 | Declarative release management |
| `jq` | any | JSON parsing in scripts |

### Phase 1 — Core Security Foundation

Phase 1 deploys: Istio · SPIRE · Consul · Vault · Keycloak · CIBA ACP · OPA · Redis · Security Gateway · OTel · Loki · Grafana · Agents

```bash
# MANUAL STEP 1 — configure AWS credentials
aws configure
# Enter: Access Key ID, Secret Access Key, region (ap-south-1), output (json)
aws sts get-caller-identity   # verify

# Step 1 — AWS resources (KMS, ECR, SNS, IAM roles)
./scripts/01_aws_infra.sh

# Step 2 — EKS cluster + node groups + EBS CSI driver (~15 min)
./scripts/02_eks_cluster.sh

# Step 3 — Point kubectl at the new cluster
./scripts/03_kubeconfig.sh

# Deploy all Phase 1 workloads (ordering enforced by helmfile `needs:`)
helmfile -f helmfile/phase1/helmfile.yaml sync

# Validate
./scripts/validate_phase1.sh
```

> **MANUAL STEP 2 — Vault recovery keys**
> When `vault-init.sh` runs for the first time, 5 recovery keys are printed once.
> Store them offline immediately — they cannot be retrieved again.

### Phase 2 — Hardening *(coming next)*

Adds: Ollama (LLM judge + embeddings) · OPAL · Cedar dynamic policies · Biscuit keys · LLM Guard · Intent-Aware Tool Catalog · Duo Mobile CIBA push · Tool hash verifier

```bash
./scripts/phase2/00_prereqs_phase2.sh
./scripts/phase2/01_gpu_nodegroup.sh
helmfile -f helmfile/phase2/helmfile.yaml sync
./scripts/validate_phase2.sh
```

### Phase 3 — Threat Management *(coming next)*

Adds: KubeArmor · AWS GuardDuty EKS runtime · OpenSearch Security Analytics · Garak red teaming CI · Posture gap analysis dashboard

```bash
./scripts/phase3/00_prereqs_phase3.sh
./scripts/phase3/01_guardduty.sh
./scripts/phase3/02_cicd_workflows.sh
./scripts/phase3/03_github_oidc.sh
helmfile -f helmfile/phase3/helmfile.yaml sync
./scripts/validate_phase3.sh
```

---

## AWS Environment

| Resource | Value |
|---|---|
| Region | `ap-south-1` |
| EKS cluster | `agentic-security` |
| Kubernetes version | `1.35` |
| Vault KMS key alias | `alias/vault-unseal` |
| SNS topic — CIBA approvals | `ciba-approvals` |
| SNS topic — security alerts | `security-alerts` |

### Node Groups

| Group | Type | Count | Workloads |
|---|---|---|---|
| `system` | `t3.medium` | 2 | CoreDNS · Consul · SPIRE · Istio |
| `application` | `t3.large` | 2–4 | Agents · Keycloak · OPA · Gateway · Vault |
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
| 2 | After Phase 1 deploy | Save Vault recovery keys offline |
| 3 | Before Phase 2 | Create Duo Security app, store creds in Vault |
| 4 | Before Phase 3 | Review KubeArmor discovery policies |

---

## References

- [Implementation decisions](implementation.md)
- [Phase 1 plan](plan_phase1.md)
- [Phase 2 plan](plan_phase2.md)
- [Phase 3 plan](plan_phase3.md)
- [SPIFFE/SPIRE](https://spiffe.io)
- [Cedar Policy Language](https://github.com/cedar-policy/cedar)
- [Biscuit Auth](https://github.com/biscuit-auth/biscuit)
- [Open Policy Agent](https://www.openpolicyagent.org)
- [Keycloak CIBA](https://www.keycloak.org/docs/latest/server_admin/#_ciba)
