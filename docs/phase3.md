# Agentic AI Security Platform — Final Architecture

Complete picture of all three phases deployed. Every component, every data flow,
every security enforcement point.

---

## Full System Architecture

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  EXTERNAL / HUMAN LAYER                                                          ║
║                                                                                  ║
║   Analyst (browser / Duo Mobile)                                                 ║
║        │                          │                                              ║
║        │ HTTPS (*.rj-lab.click)   │ Duo push notification                       ║
║        ▼                          ▼                                              ║
║   AWS ALB ── ACM wildcard TLS ──► Istio IngressGateway                          ║
╚══════════════════════════════════════════════════════════════════════════════════╝
                    │
                    │ mTLS (Istio + SPIRE X.509)
                    ▼
╔══════════════════════════════════════════════════════════════════════════════════╗
║  IDENTITY & AUTH LAYER                    namespace: infra                       ║
║                                                                                  ║
║   Keycloak (firm-internal realm)                                                 ║
║     ├── OIDC provider for all agents                                             ║
║     ├── CIBA backchannel auth endpoint                                           ║
║     ├── Users: rana (analyst), admin, viewer                                     ║
║     └── Duo SPI → Duo Mobile push on CIBA request                               ║
║                │                                                                 ║
║   CIBA ACP ◄───┘   (approval channel provider)                                  ║
║     ├── Receives CIBA auth request from Keycloak                                 ║
║     ├── Duo Mobile push → analyst approves/denies                                ║
║     ├── Falls back to AWS SNS (SMS) if Duo unavailable                           ║
║     └── Returns binding_message + auth_req_id to Keycloak                       ║
╚══════════════════════════════════════════════════════════════════════════════════╝
                    │  JWT (Keycloak-signed) + CIBA token
                    ▼
╔══════════════════════════════════════════════════════════════════════════════════╗
║  AGENT LAYER                              namespace: agents                      ║
║                                                                                  ║
║   Orchestrator Agent  ◄── SPIFFE SVID: spiffe://firm.internal/agents/orchestrator
║        │                  Biscuit token: signed with SVID private key            ║
║        │ delegates to (attenuated Biscuit)                                       ║
║        ├──► Web Search Agent     SVID: .../agents/web-search-agent               ║
║        ├──► Internal Data Agent  SVID: .../agents/internal-data-agent            ║
║        ├──► Report Gen Agent     SVID: .../agents/report-gen-agent               ║
║        └──► Email Agent          SVID: .../agents/email-agent                   ║
║                                                                                  ║
║   All agents call LiteLLM (not Claude/Ollama directly):                          ║
║        Agent → LiteLLM proxy → claude-sonnet-4-6 OR ollama-judge (fallback)     ║
╚══════════════════════════════════════════════════════════════════════════════════╝
                    │  Every tool call (mTLS, SPIFFE X.509)
                    ▼
╔══════════════════════════════════════════════════════════════════════════════════╗
║  SECURITY GATEWAY                         namespace: infra                       ║
║                                                                                  ║
║  Tool Catalog (pre-gateway)                                                      ║
║    1. Agent requests tools for intent → OPA filters by role                      ║
║    2. ollama-judge scores semantic alignment                                      ║
║    3. Returns intent-filtered tool list (web-search gets web_search, not email)  ║
║                                                                                  ║
║  Gateway — 8-layer enforcement on every tool call:                               ║
║                                                                                  ║
║   ┌─────────────────────────────────────────────────────────┐                   ║
║   │  1. mTLS + SPIFFE X.509 verify        (Istio + SPIRE)   │                   ║
║   │  2. Biscuit scope verify               (Ed25519 / SVID)  │                   ║
║   │  3. OPA baseline Rego policy           (kube-mgmt sync)  │  DENY             ║
║   │  4. Cedar task-scoped policy           (LLM-generated)   │ ──────► block     ║
║   │  5. LLM Judge intent alignment         (ollama-judge)    │  + audit log      ║
║   │  6. Tool registry hash verify          (Consul → OPAL)   │                   ║
║   │  7. Rate limit                         (Redis)           │                   ║
║   │  8. Risk score > threshold?            → HITL pause      │                   ║
║   └─────────────────────────────────────────────────────────┘                   ║
║          │ ALLOW                   │ HITL pause                                  ║
║          ▼                         ▼                                             ║
║   LLM Guard + arc_pi_taxonomy   CIBA request → Keycloak → Duo push              ║
║   (injection scan on payload)   analyst approves → agent continues              ║
║          │                                                                       ║
║          ▼                                                                       ║
║   dispatch via mTLS to MCP Tool Servers                                          ║
╚══════════════════════════════════════════════════════════════════════════════════╝
                    │
                    ▼
╔══════════════════════════════════════════════════════════════════════════════════╗
║  MCP TOOL SERVERS                         (external / sidecar)                  ║
║                                                                                  ║
║   web_search        query_internal_db      generate_report                      ║
║   send_email        read_document          ...                                   ║
║                                                                                  ║
║   Each tool registered in Consul KV with:                                        ║
║     endpoint, allowed_callers, data_classification, blast_radius, oci_digest    ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## Infrastructure & Policy Layer

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  POLICY & REGISTRY LAYER                  namespace: infra                       ║
║                                                                                  ║
║   Consul KV (service registry + policy data)                                     ║
║     ├── agents/*    agent registry (role, allowed tools, status)                 ║
║     ├── tools/*     tool registry (endpoint, hash, status)                       ║
║     └── ACL token   stored in k8s secret consul-bootstrap-acl-token             ║
║              │                                                                   ║
║              │ watches (1-2s latency)                                            ║
║              ▼                                                                   ║
║   OPAL Server + OPAL Client                                                      ║
║     └── pushes Consul KV changes to OPA bundle endpoint in real time            ║
║                        │                                                         ║
║                        ▼                                                         ║
║   OPA (Open Policy Agent)                                                        ║
║     ├── baseline.rego  — permanent floor rules (no unknown agents, no *)        ║
║     └── data/agents    — live agent registry from Consul via OPAL               ║
║                                                                                  ║
║   Hash Verifier CronJob (every 60s)                                              ║
║     ├── fetches live OCI digest from ECR                                         ║
║     ├── fetches live MCP manifest hash                                           ║
║     ├── compares against Consul expected values                                  ║
║     └── on mismatch: sets tools/<name>.status=hash_mismatch in Consul           ║
║              └──► OPAL picks up → OPA blocks the tool within 2s                 ║
║                                                                                  ║
║   Cedar (task-scoped dynamic policies)                                           ║
║     ├── generated by ollama-policy per task_id                                   ║
║     ├── formally verified before activation                                      ║
║     └── tied to specific (agent, tool, task_id) — expires when task ends        ║
╚══════════════════════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════════════════════╗
║  SECRETS & IDENTITY LAYER                                                        ║
║                                                                                  ║
║   HashiCorp Vault                         namespace: infra                       ║
║     ├── KV: secret/duo           Duo ikey/skey/host                             ║
║     ├── KV: secret/clickhouse    ClickHouse password (replaces secret/opensearch) ║
║     ├── auth: kubernetes         pod auth for vault agent injector               ║
║     └── auto-unseal: AWS KMS     alias/vault-unseal (no manual unseal needed)   ║
║                                                                                  ║
║   SPIRE                                   namespace: spire-system                ║
║     ├── SPIRE Server  issues X.509 SVIDs to all workloads                       ║
║     ├── SPIRE Agent   DaemonSet on every node, attests via k8s_sat              ║
║     ├── SPIFFE CSI    mounts SVID socket into pods                              ║
║     └── SVIDs used by: Istio (mTLS certs), Biscuit signing keys, gateway auth  ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## Inference Layer

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  INFERENCE LAYER                          namespace: infra                       ║
║                               nodeSelector: role=inference (t3.xlarge, 16GB)    ║
║                                                                                  ║
║   ollama-judge   llama3.1:8b   6Gi RAM                                          ║
║     └── used by: Security Gateway (intent alignment), Tool Catalog (filtering)  ║
║                                                                                  ║
║   ollama-policy  llama3.1:8b   6Gi RAM                                          ║
║     └── used by: Cedar engine (policy generation + validation)                  ║
║                                                                                  ║
║   ollama-embed   nomic-embed-text   2Gi RAM                                     ║
║     └── used by: injection-signals (build index), Gateway (cosine similarity)   ║
║                                                                                  ║
║   LiteLLM proxy  (model gateway)                                                 ║
║     ├── route: claude-sonnet-4-6  → Anthropic API (external)                   ║
║     ├── route: ollama-judge       → ollama-judge.infra.svc:11434               ║
║     └── route: ollama-policy      → ollama-policy.infra.svc:11434              ║
║                                                                                  ║
║   Injection Signals PVC (1Gi)                                                    ║
║     └── /data/injection_signals.pkl  — arc_pi_taxonomy embeddings               ║
║         built once by Job on deploy, mounted read-only into gateway             ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## Runtime Security Layer (Phase 3)

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  RUNTIME SECURITY LAYER                   namespace: kubearmor-system           ║
║                                                                                  ║
║   KubeArmor DaemonSet (on every node)                                           ║
║     ├── enforces syscall-level policies via LSM (BPF/AppArmor/SELinux)          ║
║     ├── blocks: shell spawns in agent pods, unexpected process exec             ║
║     ├── blocks: network calls to non-whitelisted destinations                   ║
║     ├── SPIFFE-aware — policies scoped to SPIRE SVIDs not just pod labels       ║
║     └── relay server exposes all events via gRPC on port 32767                  ║
║              │                                                                   ║
║              │ gRPC event stream                                                 ║
║              ▼                                                                   ║
║   Fluent Bit DaemonSet                                                           ║
║     ├──► Loki          (KubeArmor Runtime dashboard in Grafana)                 ║
║     └──► Kafka topic   kubearmor-events  (for Flink correlation)                ║
║                                                                                  ║
║   KubeArmor OPAL Controller                                                      ║
║     ├── watches OPA for runtime anomaly events                                   ║
║     └── on anomaly: tightens offending agent KubeArmor CRD policy in real time  ║
║         (closes the OPAL → OPA → KubeArmor enforcement feedback loop)           ║
║                                                                                  ║
║   AWS GuardDuty EKS Runtime Monitoring    (AWS managed, no pod)                 ║
║     ├── monitors EKS audit logs + node runtime behaviour                        ║
║     ├── severity >= 7 → EventBridge → SNS security-alerts topic                ║
║     └── all findings → CloudWatch → OTel Collector → Kafka (for Flink)         ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## Observability & Correlation Layer

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  EVENT COLLECTION                         namespace: observability               ║
║                                                                                  ║
║   OTel Collector  (receives from all namespaces via gRPC/HTTP)                  ║
║     ├── Security Gateway logs       → Loki + Kafka topic security-gateway-events║
║     ├── Agent logs                  → Loki + Kafka                             ║
║     ├── Keycloak / CIBA ACP logs    → Loki                                     ║
║     ├── OPA decision logs           → Loki + Kafka topic opa-decisions         ║
║     ├── Hash Verifier results       → Loki                                     ║
║     └── GuardDuty (CloudWatch)      → Kafka topic guardduty-events             ║
║                                                                                  ║
║   Fluent Bit (KubeArmor only — DaemonSet in kubearmor-system)                  ║
║     └── KubeArmor relay gRPC        → Loki + Kafka topic kubearmor-events      ║
║                                                                                  ║
║   NOTE: OpenSearch was originally the correlation + analytics backend.          ║
║   Removed — replaced by Flink (CEP) + ClickHouse (analytics).                  ║
║   See docs/observability.md "OpenSearch Decision Record" for full reasoning.    ║
╚══════════════════════════════════════════════════════════════════════════════════╝
                    │
                    ▼
╔══════════════════════════════════════════════════════════════════════════════════╗
║  CORRELATION ENGINE                       namespace: observability               ║
║                                                                                  ║
║   Apache Kafka  (event buffer — 3 brokers, 20Gi each)                          ║
║     ├── topic: security-gateway-events                                          ║
║     ├── topic: opa-decisions                                                    ║
║     ├── topic: kubearmor-events                                                 ║
║     └── topic: guardduty-events                                                 ║
║              │                                                                   ║
║              │ Kafka consumer (exactly-once, event-time watermarks)             ║
║              ▼                                                                   ║
║   Apache Flink  (1 JobManager + 2 TaskManagers)                                 ║
║     ├── CEP Rule 1: injection → tool call within 60s, same agent_id            ║
║     │     Pattern.begin("inject").where(scan=unsafe)                            ║
║     │            .next("toolcall").where(event=tool_call).within(60s)          ║
║     ├── CEP Rule 2: probe → inject → toolcall sequence within 2 min            ║
║     │     (3-event ordered pattern — only Flink can do this)                   ║
║     ├── Interval Join: KubeArmor block ⋈ GuardDuty finding                    ║
║     │     same node_name, within ±5 min window                                  ║
║     ├── CEP Rule 3: Biscuit scope violation > 3 times in 10 min                ║
║     └── All enriched events → ClickHouse                                        ║
║         All correlation hits → SNS security-alerts + ClickHouse alerts table   ║
║                                                                                  ║
║   ClickHouse  (single node lab, 30Gi EBS)                                       ║
║     ├── table: security_events    (all enriched events, TTL 1 day)             ║
║     ├── table: correlation_alerts (Flink CEP hits, TTL 7 days)                 ║
║     └── table: gap_analysis       (daily policy coverage report)                ║
╚══════════════════════════════════════════════════════════════════════════════════╝
                    │
                    ▼
╔══════════════════════════════════════════════════════════════════════════════════╗
║  DASHBOARDS & ALERTING                    namespace: observability               ║
║                                                                                  ║
║   Loki  (log store — all structured JSON from OTel + Fluent Bit)                ║
║   Prometheus  (metrics — request rates, denial rates, HITL counts)              ║
║   ClickHouse  (correlated events + analytics)                                   ║
║        │                                                                         ║
║        ▼                                                                         ║
║   Grafana  (5 dashboards + public HTTPS at grafana.rj-lab.click)               ║
║     ├── Security Gateway     Loki   — allow/deny per layer, HITL triggers       ║
║     ├── Agent Activity       Loki   — per-agent log stream                      ║
║     ├── KubeArmor Runtime    Loki   — syscall blocks per pod/namespace          ║
║     ├── Threat Correlations  ClickHouse — Flink CEP hits, attack sequences     ║
║     └── Security Posture     ClickHouse + Prometheus                            ║
║                                 policy coverage %, injection rate,              ║
║                                 Biscuit violations, GuardDuty findings,         ║
║                                 hash mismatches, HITL trigger rate              ║
║                                                                                  ║
║   SNS topic: security-alerts                                                     ║
║     ├── GuardDuty severity >= 7                                                 ║
║     ├── Flink CEP correlation hits                                              ║
║     └── Hash Verifier mismatches                                                ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## CI/CD & Red Team Layer (Phase 3)

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  CI/CD SECURITY PIPELINE                  GitHub Actions                         ║
║                                                                                  ║
║   On every push to agents/, policies/, services/:                                ║
║                                                                                  ║
║   ┌──────────────────────────────────────────────────────────┐                  ║
║   │  Checkov (IaC scanning)                                   │                  ║
║   │    ├── helmfile/ → Helm chart misconfigurations           │                  ║
║   │    ├── manifests/ → K8s security misconfigs               │                  ║
║   │    └── SARIF → GitHub Security tab                        │                  ║
║   └──────────────────────────────────────────────────────────┘                  ║
║                                                                                  ║
║   Nightly at 02:00 UTC:                                                          ║
║   ┌──────────────────────────────────────────────────────────┐                  ║
║   │  Garak red team                                           │                  ║
║   │    ├── probes: PromptInjection, Dan jailbreak, SystemLeak │                  ║
║   │    ├── arc_pi_taxonomy full suite                         │                  ║
║   │    └── fail on critical/high findings                     │                  ║
║   └──────────────────────────────────────────────────────────┘                  ║
║                                                                                  ║
║   IAM: GitHub Actions assumes github-actions-red-team role                      ║
║        via OIDC (no long-lived keys stored in GitHub secrets)                   ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## AWS Infrastructure Layer

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  AWS INFRASTRUCTURE                       region: ap-south-1                     ║
║                                                                                  ║
║   EKS Cluster: agentic-security  (Kubernetes 1.35)                              ║
║     ├── Nodegroup: system        3 × t3.medium   (4GB)  role=system             ║
║     │     Pods: istiod, spire, consul, vault, keycloak, opa, redis,             ║
║     │           security-gateway, ciba-acp, tool-catalog, opal,                 ║
║     │           litellm, kafka, flink, clickhouse                               ║
║     ├── Nodegroup: application   2 × t3.large    (8GB)  role=application        ║
║     │     Pods: agents (orchestrator, web-search, internal-data, email, report) ║
║     ├── Nodegroup: observability 1 × t3.medium   (4GB)  role=observability      ║
║     │     Pods: otel-collector, loki, grafana, prometheus                       ║
║     └── Nodegroup: inference     2 × t3.xlarge   (16GB) role=inference          ║
║           Pods: ollama-judge, ollama-policy, ollama-embed                       ║
║                                                                                  ║
║   Persistent resources (survive nightly destroy):                                ║
║     ├── KMS key        alias/vault-unseal    Vault auto-unseal                  ║
║     ├── ECR repos      agentic/*             container images                   ║
║     ├── SNS topics     ciba-approvals        CIBA delivery channel              ║
║     │                  security-alerts       GuardDuty + Flink CEP hits         ║
║     ├── ACM cert       *.rj-lab.click        wildcard TLS (free)                ║
║     ├── Route 53       rj-lab.click          DNS (wired to ALB on deploy)       ║
║     └── IAM roles      vault-unseal-role, ciba-acp-role,                        ║
║                        ecr-puller-role, hash-verifier-role,                     ║
║                        AmazonEKSLoadBalancerControllerRole                      ║
║                                                                                  ║
║   Destroyed nightly (cost saving):                                               ║
║     EKS cluster, EC2 nodes, NAT Gateway, ALB, EBS volumes                      ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## Network & mTLS Topology

```
╔══════════════════════════════════════════════════════════════════════════════════╗
║  NETWORK SECURITY                                                                ║
║                                                                                  ║
║   All inter-pod communication: Istio sidecar mTLS (PeerAuthentication STRICT)  ║
║   All pod identities:          SPIRE X.509 SVIDs (rotated every 1h)             ║
║   All inbound external:        ALB TLS termination → Istio IngressGateway       ║
║                                                                                  ║
║   Namespace isolation (NetworkPolicy):                                           ║
║                                                                                  ║
║   agents ns ──────────────────────► infra ns (security-gateway only)            ║
║                                            │                                     ║
║                    ┌───────────────────────┼──────────────────────┐             ║
║                    ▼                       ▼                      ▼             ║
║              infra/consul          infra/vault              infra/opa           ║
║                    │                       │                      │             ║
║                    └────────── infra/opal ─┘                      │             ║
║                                                         infra/redis             ║
║                                                                    │             ║
║   kubearmor-system ◄──── runtime policy updates ─── infra/opal ──┘             ║
║                                                                                  ║
║   observability ns ◄──── OTel gRPC ──── all namespaces                          ║
╚══════════════════════════════════════════════════════════════════════════════════╝
```

---

## Complete Data Flow — Single Agent Tool Call

```
 1. Agent (web-search) calls Tool Catalog:
       "intent: search public web, agent_type: web-search-agent"
    └─► OPA filters by role → ollama-judge semantic check
    └─► Returns [web_search] (not send_email, not query_internal_db)

 2. Agent calls Security Gateway: POST /tool/web_search
       Headers: mTLS cert (SPIRE SVID), Biscuit token, task_id

 3. Gateway Layer 1 — mTLS verify:
       Istio validates SPIFFE X.509 SVID for web-search-agent ✓

 4. Gateway Layer 2 — Biscuit verify:
       Token signed with agent SVID key, scope includes web_search ✓

 5. Gateway Layer 3 — OPA baseline:
       agent_type=web-search-agent, tool=web_search, status=active ✓

 6. Gateway Layer 4 — Cedar task policy:
       task_id=t123, policy: web-search-agent MAY use web_search FOR t123 ✓

 7. Gateway Layer 5 — LLM Judge:
       ollama-judge: "search public web" aligns with web_search, score=0.92 ✓

 8. Gateway Layer 6 — Hash verify:
       Consul: tools/web_search.oci_digest matches live ECR digest ✓

 9. Gateway Layer 7 — Rate limit:
       Redis: web-search-agent 12/100 calls this minute ✓

10. Gateway Layer 8 — Risk score:
       score = 0.12 (public web search, low blast radius) < threshold ✓

11. LLM Guard injection scan:
       input: "search for latest AI security papers"
       cosine similarity against arc_pi_taxonomy index = 0.08 < 0.70 ✓

12. Gateway dispatches to MCP web_search tool via mTLS

13. All 12 steps logged as structured JSON → OTel → Loki + Kafka

14. Flink consumes gateway event from Kafka:
       no injection flag → CEP Rule 1 window starts but stays open
       no match within 60s → window expires, no alert

15. ClickHouse stores enriched event for dashboard queries
```

---

## Security Enforcement Matrix

| Threat | Detected by | Enforced by | Response |
|---|---|---|---|
| Unknown agent calls gateway | OPA baseline Rego | Gateway Layer 3 | Block + audit log |
| Agent calls out-of-scope tool | Biscuit token scope | Gateway Layer 2 | Block + Flink CEP alert |
| Tool intent mismatch | LLM Judge (ollama-judge) | Gateway Layer 5 | Block + audit log |
| Compromised tool image | Hash Verifier + OPAL | Gateway Layer 6 | Block within 60s |
| Prompt injection in input | LLM Guard + arc_pi_taxonomy | Gateway (post-allow) | Block + audit log |
| High-risk action (exfiltration) | Risk score engine | Gateway Layer 8 | HITL pause → Duo push |
| Agent spawns shell | KubeArmor LSM | Kernel syscall block | Block + Fluent Bit → Kafka |
| Compromised node | GuardDuty EKS runtime | AWS managed | SNS alert + Flink join |
| Injection then tool call | Flink CEP Rule 1 | Post-detection | SNS critical alert |
| Probe → inject → exfiltrate sequence | Flink CEP Rule 2 | Post-detection | SNS critical alert |
| KubeArmor + GuardDuty same node | Flink interval join | Post-detection | SNS critical alert |
| Policy coverage gap | Gap Analysis CronJob | Daily report | SNS + ClickHouse dashboard |
| IaC misconfiguration | Checkov CI | Pre-deploy | PR blocked |
| Gateway vulnerability | Garak red team | Nightly CI | PR blocked if critical |

---

## Phase Boundary Summary

| Component | Phase 1 | Phase 2 | Phase 3 |
|---|---|---|---|
| Istio mTLS (strict) | ✓ | | |
| SPIRE workload identity | ✓ | | |
| OPA baseline Rego | ✓ | | |
| Consul agent + tool registry | ✓ | | |
| Vault + KMS auto-unseal | ✓ | | |
| Keycloak OIDC + CIBA SMS | ✓ | | |
| CIBA ACP + AWS SNS | ✓ | | |
| Redis rate limiting | ✓ | | |
| Security Gateway (mTLS + OPA) | ✓ | | |
| OTel + Loki + Grafana | ✓ | | |
| Agents (4 types) | ✓ | | |
| Ollama (judge/policy/embed) | | ✓ | |
| OPAL real-time policy sync | | ✓ | |
| Cedar task-scoped policies | | ✓ | |
| Biscuit delegation tokens | | ✓ | |
| LLM Guard + injection signals | | ✓ | |
| Intent-aware Tool Catalog | | ✓ | |
| Duo Mobile CIBA push | | ✓ | |
| Tool hash integrity (CronJob) | | ✓ | |
| LiteLLM model proxy | | ✓ | |
| KubeArmor runtime enforcement | | | ✓ |
| GuardDuty EKS monitoring | | | ✓ |
| Kafka event bus | | | ✓ |
| Flink CEP correlation | | | ✓ |
| ClickHouse analytics store | | | ✓ |
| Fluent Bit (KubeArmor → Kafka + Loki) | | | ✓ |
| Gap Analysis CronJob | | | ✓ |
| Grafana posture dashboard (ClickHouse) | | | ✓ |
| Garak red team CI | | | ✓ |
| Checkov IaC scanning CI | | | ✓ |
| ~~OpenSearch Security Analytics~~ | | | ~~removed~~ |

---

## Cost Summary — Full Stack Running (10h/day, nightly destroy)

| Layer | Components | Cost/month |
|---|---|---|
| EKS control plane | 1 cluster | ~$72 |
| system nodegroup | 3 × t3.medium | ~$55 |
| application nodegroup | 2 × t3.large | ~$60 |
| observability nodegroup | 1 × t3.medium | ~$18 |
| inference nodegroup | 2 × t3.xlarge | ~$110 |
| NAT Gateway | 1 | ~$14 |
| ALB | 1 | ~$7 |
| EBS (Kafka 60Gi + ClickHouse 30Gi + misc) | ~110 Gi | ~$11 |
| KMS + ECR + SNS + ACM + Route53 | persistent | ~$2 |
| **Total** | | **~$349/month** |

Compared to running 24/7 (no nightly destroy): ~$1,050/month.
Nightly destroy saves ~$700/month.

### What OpenSearch would have added (removed)

OpenSearch (3 nodes × t3.medium + 3 × 30Gi EBS) would have added ~$82/month
for functionality now fully covered by Flink + ClickHouse at ~$9/month (EBS only).
Removing OpenSearch saves **~$73/month** with no loss of capability.
See `docs/observability.md` OpenSearch Decision Record for full reasoning.

---

## References

- [Observability options guide](observability.md)
- [Phase 2 component guide](phase2.md)
- [Vault operations guide](vault.md)
- [Apache Flink](https://flink.apache.org)
- [FlinkCEP](https://nightlies.apache.org/flink/flink-docs-stable/docs/libs/cep)
- [ClickHouse](https://clickhouse.com/docs)
- [KubeArmor](https://kubearmor.io)
- [SPIFFE/SPIRE](https://spiffe.io)
- [Cedar Policy Language](https://github.com/cedar-policy/cedar)
- [Biscuit Auth](https://github.com/biscuit-auth/biscuit)
- [arc_pi_taxonomy](https://github.com/Arcanum-Sec/arc_pi_taxonomy)
- [Garak](https://github.com/leondz/garak)
