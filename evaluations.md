# Agentic AI Security — Technology Evaluations

This document records every technology decision made during the design of the agentic AI security stack — what was considered, what was chosen, and why alternatives were ruled out.

---

## 1. Registry Store

**Decision: Consul**

| Option | Considered | Verdict |
|---|---|---|
| **PostgreSQL** | Initial choice | Rejected — relational DB is over-engineered for a key-value registry; schema migrations add operational friction; no native watch/subscribe for OPAL |
| **etcd** | Evaluated | Rejected — designed for Kubernetes internals, not application data; operationally heavy to run a dedicated etcd cluster; limited query capability |
| **Consul** ✓ | Chosen | Native KV store with watches; OPAL has first-class Consul data source; pairs naturally with Vault (already in stack); built-in ACLs; service health checks; `*.service.consul` DNS integrates with tool registry |
| **NATS JetStream** | Evaluated | Strong option — native KV watch/subscribe, lightweight; not chosen because Consul covers all needs and the team would need to operate both Consul (for service mesh) and NATS |
| **Git + OPAL** | Evaluated | Elegant for change-controlled registries; rejected for runtime use because emergency revocation still requires a Git push (~30s propagation) |

---

## 2. Identity Provider (IDP)

**Decision: Keycloak (self-hosted)**

| Option | Considered | Verdict |
|---|---|---|
| **Keycloak** ✓ | Chosen | Self-hosted; full control; no data egress; CIBA supported since v18 (stable); open source; consistent with self-hosted stack posture |
| **Okta** | Evaluated | Rejected — SaaS; data egress to Okta servers (compliance concern for financial services); per-user licensing cost; vendor lock-in; introduces the only SaaS dependency into an otherwise self-hosted stack |
| **Auth0** | Evaluated | Same concerns as Okta — SaaS, data egress, licensing cost |

---

## 3. CIBA Notification Delivery

**Decision: AWS SNS (SMS) + Duo Mobile (push)**

| Option | Considered | Verdict |
|---|---|---|
| **Twilio Verify** | Initial suggestion | Rejected — external SaaS dependency; team cannot use it |
| **AWS SNS → SMS** ✓ | Chosen (primary) | No app required; phone number stored in Keycloak user attribute; zero new infrastructure since SNS already in stack |
| **Duo Mobile** ✓ | Chosen (rich UX) | Authenticator app with Approve/Deny push buttons; Keycloak Duo SPI plugin handles integration; no custom app to build |
| **Custom FCM/APNs app** | Evaluated | Rejected — requires building and maintaining an iOS/Android app; Duo Mobile covers this need without custom development |
| **Google Authenticator / Authy / FreeOTP** | Evaluated | Rejected — TOTP-only; no push notification capability; cannot receive or respond to a CIBA approval request |

---

## 4. Human-in-the-Loop (HITL)

**Decision: Claude tool use interrupt pattern (Anthropic API native)**

| Option | Considered | Verdict |
|---|---|---|
| **LangGraph interrupt()** | Initial choice | Rejected — LangChain ecosystem, not Anthropic; inconsistent with the Anthropic/Claude stack chosen for agent inference |
| **Custom webhook** | Evaluated | Workable but redundant — Claude's tool use pattern already provides the interrupt mechanism natively |
| **Claude tool use interrupt** ✓ | Chosen | Native to Anthropic API; Claude calls `request_human_approval` tool; orchestration layer pauses; notification sent via AWS SNS / Duo Mobile (already in stack); no new framework |

---

## 5. Runtime Threat Detection

**Decision: KubeArmor (with AWS GuardDuty as Phase 1/3 managed layer)**

| Option | Considered | Verdict |
|---|---|---|
| **Falco** | Initial choice | Replaced — detect-only (no enforcement); dynamic rule support is partial (SIGHUP hot reload, still file-based); no SPIFFE identity awareness |
| **AWS GuardDuty for EKS** | Evaluated | Chosen for Phase 1/3 — managed service, zero ops overhead, AWS-native; limitation: AWS manages rules, limited customisation |
| **Tetragon (Cilium)** | Evaluated | Strong option — pure eBPF, enforcement capable, K8s CRD-based dynamic rules; not chosen over KubeArmor because KubeArmor has SPIFFE identity awareness and Discovery Engine |
| **KubeArmor** ✓ | Chosen (Phase 2+) | Dynamic rules via K8s CRDs (apply/delete at runtime); SPIFFE/SPIRE identity awareness; Discovery Engine auto-generates policies from observed runtime behavior; enforce mode (block, not just alert); OPAL can drive CRD updates |
| **Tracee** | Evaluated | Open source eBPF alternative to Falco; detect-only; smaller community; no SPIFFE awareness; not chosen |
| **Sysdig Secure** | Evaluated | Commercial product built on Falco; rejected — commercial cost; detect-only |

---

## 6. Dynamic Policy Engine

**Decision: Cedar (dynamic layer) + OPA (baseline layer)**

| Option | Considered | Verdict |
|---|---|---|
| **OPA only (static Rego)** | Initial choice | Insufficient for dynamic requirement — Rego is designed for human-written rules; LLM-generated Rego is hard to safely validate; OPAL pushes updates but rules are still human-authored |
| **OPA with LLM-generated data** | Evaluated | Better than LLM-generated Rego — LLM writes data, human-written rules evaluate it; rejected because it still requires humans to pre-write all policy logic; cannot handle novel intent scenarios |
| **Cerbos** | Evaluated | Good option — YAML policies via REST API, LLM-friendly format, cloud-agnostic; not chosen because Cedar provides formal verification that Cerbos lacks |
| **Gateway-native evaluation** | Evaluated | Most portable option — gateway evaluates LLM JSON directly; rejected as sole engine because it lacks formal verification guarantees |
| **Cedar** ✓ | Chosen (dynamic layer) | Purpose-built for programmatic/LLM-generated policies; formal verifier proves generated policy cannot exceed baseline before apply; Apache 2.0 open source; cloud-agnostic (pure Rust library); structured syntax safer for LLM generation than Rego |
| **OPA** ✓ | Retained (baseline layer) | CNCF project, neutral governance; best for permanent human-written floor rules; already in stack |

---

## 7. Policy Format for LLM-Generated Rules

**Decision: Cedar (structured policy language)**

| Option | Considered | Verdict |
|---|---|---|
| **LLM-generated Rego** | Considered | Rejected — Rego is a Datalog-derived logic language; LLM-generated Rego is hard to validate safely; unstructured text output; no formal verifier to prove it cannot exceed a baseline; a malformed rule can silently allow everything |
| **LLM-generated JSON data (fed to static Rego rules)** | Evaluated | Safer than generated Rego — rules stay human-authored; data is LLM-supplied; rejected because all policy logic must be pre-written; cannot adapt to new tool types or agent intents not anticipated at authoring time |
| **LLM-generated YAML (Cerbos)** | Evaluated | More readable than Rego for LLM generation; Cerbos has no formal verifier; rejected in favour of Cedar |
| **LLM-generated Cedar** ✓ | Chosen | Cedar's structured syntax (`permit (principal, action, resource) when { ... }`) is narrow enough for LLMs to generate reliably; Cedar's formal verifier (`cedar-policy` Rust crate) proves the generated policy is strictly contained within the OPA baseline before apply; Apache 2.0; cloud-agnostic |

---

## 8. Self-Attenuating Delegation Tokens

**Decision: Biscuits**

| Option | Considered | Verdict |
|---|---|---|
| **Macaroons** | Initial choice | Replaced — use HMAC (symmetric key); every verifier must share the root secret with the issuer; creates shared secret dependency across all agents and gateways |
| **OAuth 2.0 Token Exchange (RFC 8693)** | Evaluated | Viable via Keycloak; adds a round-trip to Keycloak on every delegation; not chosen as primary — Biscuits handle delegation without a central server call |
| **Biscuits** ✓ | Chosen | Ed25519 public key cryptography — verifier only needs public key, no shared secret; SPIFFE SVID key pair IS the Biscuit signing key (no new key management); Authority block + Restriction blocks maps exactly to orchestrator + sub-agent delegation; Datalog facts embedded in token complement Cedar policy; open source |

---

## 9. AWS Pod IAM Credentials

**Decision: EKS Pod Identity**

| Option | Considered | Verdict |
|---|---|---|
| **IRSA** (IAM Roles for Service Accounts) | Initial choice | Replaced — requires OIDC provider setup per cluster; trust policies reference cluster-specific OIDC issuer URL; harder to reuse roles across clusters; operational friction |
| **EKS Pod Identity** ✓ | Chosen | No OIDC provider setup; role association managed directly in EKS via `eks:CreatePodIdentityAssociation`; simpler trust policy (`eks.amazonaws.com` service principal); roles reusable across clusters; AWS's recommended approach going forward |
| **Long-lived IAM credentials in pods** | Not considered | Rejected outright — violates zero trust; secrets in pods |

---

## 10. SPIRE Workload Attestation

**Decision: k8s_sat (Kubernetes Service Account Token)**

| Option | Considered | Verdict |
|---|---|---|
| **AWS EKS node attestor (aws_iid)** | Initial suggestion | Rejected — ties workload identity to EC2 instance identity documents; AWS-specific; breaks if cluster moves to GCP/Azure/on-prem or dev/staging runs on local Kubernetes |
| **k8s_sat** ✓ | Chosen | Cloud-agnostic — works identically on EKS, GKE, AKS, minikube, on-prem; uses K8s API server's cryptographic signing of service account tokens; SPIRE entry scoped by namespace + service account + pod labels; no cloud vendor dependency in the identity layer |

---

## 11. MCP Tool Discovery

**Decision: Intent-Aware Tool Catalog (replaces vanilla MCP tools/list)**

| Option | Considered | Verdict |
|---|---|---|
| **Vanilla MCP tools/list** | Initial choice | Rejected — loads ALL tools at session start regardless of current task; violates least privilege; widens prompt injection attack surface (agent knows about tools it should not call for this intent) |
| **Per-agent-type MCP servers** | Evaluated | Partial improvement — static segmentation by agent type; does not handle fine-grained intent variation within an agent type |
| **Intent-Aware Tool Catalog** ✓ | Chosen | Agent sends current intent to catalog; catalog queries OPA + LLM judge; returns only tools justified by that specific intent; MCP retained for invocation only; attack surface shrinks to intent-relevant tools only |

---

## 12. DNS Infrastructure

**Decision: CoreDNS + Consul DNS (no separate DNS server)**

| Option | Considered | Verdict |
|---|---|---|
| **Separate internal DNS server (BIND/Unbound)** | Considered | Not needed for Kubernetes-only workloads — over-engineering |
| **CoreDNS (K8s built-in)** ✓ | Chosen | Already present in every Kubernetes cluster; handles all `*.firm.internal` service resolution; zero additional infrastructure |
| **Consul DNS interface** ✓ | Chosen | Handles `*.service.consul` service discovery tied to tool registry; CoreDNS forwards `*.consul` queries to Consul DNS via one ConfigMap entry |

Note: SPIFFE trust domain (`firm.internal`) is not a DNS name — SPIRE never resolves it via DNS. Identity is in the X.509 certificate URI SAN.

---

## 13. Deployment Platform

**Decision: AWS EKS**

| Option | Considered | Verdict |
|---|---|---|
| **Self-managed Kubernetes** | Considered | More control but significantly higher ops burden for control plane; not justified given EKS managed control plane |
| **AWS ECS / Fargate** | Considered | Simpler than EKS; rejected because SPIRE k8s_sat attestor, Istio service mesh, and KubeArmor all require Kubernetes — ECS would break the security stack |
| **AWS EKS** ✓ | Chosen | Managed K8s control plane; consistent with AWS SNS (already in stack); supports all security components (SPIRE, Istio, KubeArmor, OPA); GPU node groups for Ollama; EKS Pod Identity for AWS service access |
| **GKE / AKS** | Not chosen | Team is on AWS; SNS integration already in place; switching clouds would add complexity without benefit at this stage |

---

## 14. Mobile Push for CIBA (Authenticator App)

**Decision: Duo Mobile**

| Option | Considered | Verdict |
|---|---|---|
| **Google Authenticator** | Evaluated | Rejected — TOTP-only; no push notifications; cannot receive CIBA approval requests |
| **Authy / FreeOTP** | Evaluated | Same as Google Authenticator — TOTP-only |
| **Microsoft Authenticator** | Evaluated | Push capable but tied to Azure AD ecosystem; inconsistent with Keycloak-based IDP |
| **Custom FCM/APNs app** | Evaluated | Rejected — requires building and maintaining iOS/Android app; Duo Mobile eliminates this need |
| **Duo Mobile** ✓ | Chosen | Authenticator app with Approve/Deny push + binding message display; Keycloak Duo SPI plugin handles integration; widely used in enterprise MFA; no custom app development needed |

---

## 15. Kubernetes Deployment Orchestration

**Decision: Helmfile**

| Option | Considered | Verdict |
|---|---|---|
| **Individual `helm` + `kubectl` commands** | Initial approach | Rejected — no dependency ordering between releases; operator must manually sequence 15+ installs and know the correct order; post-install configuration (hooks) must be run manually after each release; error-prone and not reproducible |
| **Kustomize** | Evaluated | Good for managing Kubernetes manifests; no native Helm release management; `needs:` ordering and `postsync` hooks are absent; would require a separate orchestration layer on top |
| **ArgoCD / Flux (GitOps)** | Evaluated | Excellent for continuous reconciliation; adds significant operational complexity (new control plane) for an initial deployment; better suited as a day-2 operational tool after the initial stack is running |
| **Helmfile** ✓ | Chosen | Declarative wrapper over Helm; `needs:` field enforces release ordering (e.g. SPIRE before Consul, Consul before Vault); `hooks:` with `postsync` events run post-install scripts automatically; single `helmfile sync` command deploys the entire phase; idempotent — safe to re-run; integrates Helm values, per-environment overrides, and shell hooks in one file |

---

## 16. Local LLM Inference Server

**Decision: Ollama**

| Option | Considered | Verdict |
|---|---|---|
| **vLLM** | Evaluated | High-throughput production serving; optimised for batched inference at scale; higher memory overhead; operational complexity greater than needed for three isolated inference instances |
| **llama.cpp server** | Evaluated | Lightweight; no Helm chart; no GPU memory management; less mature API surface for production use |
| **Hugging Face TGI (Text Generation Inference)** | Evaluated | Production-grade; more complex configuration; separate deployment per model; good but heavier than Ollama for this use case |
| **Ollama** ✓ | Chosen | Simple Helm chart (`otwld/ollama-helm`); built-in model pull on startup; GPU-enabled via NVIDIA device plugin; clean REST API (`/api/generate`, `/api/tags`); three isolated instances deployable with identical chart + different values; nomic-embed-text supported natively for semantic embedding |

Three separate Ollama instances are deployed to preserve isolation between concerns:
- `ollama-judge` — LLM Judge for Intent-Aware Tool Catalog
- `ollama-policy` — Policy Generation + Validation LLM for Cedar rule generation
- `ollama-embed` — Embedding model (nomic-embed-text) for semantic injection detection

---

## 17. Agent Framework

**Decision: Anthropic Claude API (native tool use) — no external agent framework**

| Option | Considered | Verdict |
|---|---|---|
| **LangGraph** | Initial suggestion | Rejected — LangChain ecosystem; LangGraph's `interrupt()` is the LangChain HITL pattern, not Anthropic's; introducing LangChain adds a dependency layer between the orchestrator and the Claude API that obscures tool call events needed for security interception |
| **Google ADK (Agent Development Kit)** | Evaluated | Rejected — Google-centric; designed for Gemini models; inconsistent with Claude/Anthropic stack |
| **AutoGen (Microsoft)** | Evaluated | Multi-agent orchestration; adds a framework layer; Azure-centric defaults; no native Claude CIBA integration |
| **CrewAI** | Evaluated | Open source; simpler than LangGraph; still abstracts away the raw tool use events that the security gateway must inspect |
| **Claude API native tool use** ✓ | Chosen | The Anthropic API's tool use protocol gives the orchestration layer direct access to every tool call before and after execution; `request_human_approval` is a native tool that pauses the agent and triggers CIBA; the security gateway intercepts all tool calls at the API level without framework coupling; no new library dependency |

---

## 18. Tool Integrity Verification

**Decision: OCI image digest + MCP manifest SHA-256, verified by background CronJob**

| Option | Considered | Verdict |
|---|---|---|
| **Source code hash** | Initial framing | Inapplicable — API endpoint tools have no source artifact accessible at runtime; a source hash cannot be verified from inside the cluster |
| **Binary artifact hash** | Initial framing | Inapplicable for the same reason — API endpoints are not binary files shipped to the cluster |
| **Re-computing hash on every tool call** | Evaluated | Too expensive — pulling an OCI manifest or fetching a remote endpoint on every call adds latency and creates a denial-of-service vector if the registry is slow |
| **OCI image digest + MCP manifest hash (background verifier)** ✓ | Chosen | OCI image digest is fetched from the Kubernetes API (already known to kubelet — no re-pull needed) and compared against the hash registered at tool onboarding; MCP manifest hash (SHA-256 of the tool's capability declaration) is fetched from the live endpoint and compared against registration-time hash; a 60-second CronJob runs both checks; on mismatch, `tools/<name>.status` is set to `hash_mismatch` in Consul; OPAL propagates to OPA within seconds; gateway denies tool calls without latency on the hot path |

---

## 19. Prompt Injection Detection

**Decision: LLM Guard + Rebuff + arc_pi_taxonomy semantic index**

| Option | Considered | Verdict |
|---|---|---|
| **Regex / keyword blocklist** | Initial baseline | Insufficient — trivially evaded by rephrasing; does not catch semantic injection patterns |
| **LLM Guard** ✓ | Chosen (scanner layer) | Open source; integrates as a gateway sidecar; multiple scanners: `PromptInjection`, `Toxicity`, `Secrets`, `InvisibleText`; Python library embeds cleanly in the FastAPI gateway |
| **Rebuff** ✓ | Chosen (heuristic layer) | Canary token injection — embeds a unique token in the system prompt; if it appears in the model output, a prompt hijack is confirmed; complementary to LLM Guard's classifier approach |
| **arc_pi_taxonomy semantic index** ✓ | Chosen (embedding layer) | The Arcanum Security arc_pi_taxonomy is a curated taxonomy of prompt injection attack classes; embeddings are pre-built using `nomic-embed-text` (via ollama-embed) and stored in a PVC; incoming text is embedded at scan time and cosine-compared against the index; catches novel phrasing of known attack classes that keyword and classifier approaches miss |
| **OpenAI Moderation API** | Evaluated | Rejected — SaaS; data egress; inconsistent with self-hosted posture; billed per call |

---

## 20. Automated Red Teaming

**Decision: Garak + arc_pi_taxonomy test suite**

| Option | Considered | Verdict |
|---|---|---|
| **Manual penetration testing only** | Initial approach | Insufficient — manual tests run infrequently; do not catch regressions introduced by policy or agent code changes |
| **OWASP LLM Top 10 checklist** | Evaluated | Useful reference but not an executable test suite; cannot be integrated into CI/CD |
| **Promptfoo** | Evaluated | Good for LLM output testing and red team scenarios; less focused on agentic security patterns; Garak has broader coverage of injection and jailbreak probe categories |
| **Garak** ✓ | Chosen | Open source LLM red team framework; probe categories cover prompt injection, jailbreak (DAN variants), system prompt leakage, and data exfiltration; runs as a CLI in GitHub Actions; structured JSONL report output parseable by CI gate script |
| **arc_pi_taxonomy** ✓ | Chosen (paired with Garak) | The same taxonomy used for semantic injection detection at runtime; used as a test corpus in CI — every class of known prompt injection attack is replayed against the gateway; if the gateway's detection improves or regresses, the CI run reflects it |

---

## 21. IaC Security Scanning

**Decision: Checkov**

| Option | Considered | Verdict |
|---|---|---|
| **Trivy (misconfiguration scanning)** | Evaluated | Excellent container image vulnerability scanner; misconfiguration scanning is present but secondary to its image scanning focus; Checkov has broader Helm/K8s manifest policy coverage |
| **Snyk IaC** | Evaluated | Commercial SaaS tier for full feature set; data egress; inconsistent with self-hosted posture |
| **kube-score** | Evaluated | Kubernetes-only; no Helm chart awareness; lighter coverage than Checkov |
| **Checkov** ✓ | Chosen | Open source (Bridgecrew/Prisma); native Helm chart scanning (renders templates then checks); Kubernetes manifest checks; SARIF output integrates with GitHub Security tab; runs in GitHub Actions with `bridgecrewio/checkov-action`; covers CIS Kubernetes Benchmark checks out of the box |

---

## 22. SIEM and Correlation Engine

**Decision: OpenSearch Security Analytics**

| Option | Considered | Verdict |
|---|---|---|
| **Elasticsearch / Kibana (ELK)** | Evaluated | Strong option; Elastic's SIEM is mature; licensing changed — Basic tier lacks SIEM correlation features; Enterprise tier required for Security; Elastic also restricted open source distribution |
| **Splunk** | Evaluated | Industry standard SIEM; commercial licensing cost per GB/day; not appropriate for a self-hosted budget-conscious stack |
| **Grafana + Loki (Phase 1 observability)** | Evaluated as sole SIEM | Grafana/Loki handles metrics and log visualisation well but lacks structured correlation rule engine (event A followed by event B within N seconds across sources); retained for dashboards, not SIEM |
| **OpenSearch Security Analytics** ✓ | Chosen | Fully open source (Apache 2.0); fork of Elasticsearch with security features restored to open source; Security Analytics plugin provides correlation rules engine natively; accepts OpenTelemetry output from existing OTel collector; no licensing cost; self-hosted consistent with stack posture |

---

## 23. LLM Model Proxy

**Decision: LiteLLM**

| Option | Considered | Verdict |
|---|---|---|
| **Direct Anthropic API calls from agents** | Initial approach | Works for single-model setups; no unified rate limiting; no model fallback; switching from Claude to Ollama for specific agent types requires per-agent code changes |
| **Custom proxy service** | Evaluated | Full control but significant build effort to replicate what LiteLLM already provides |
| **OpenRouter** | Evaluated | SaaS; data egress; adds an external dependency for all model traffic |
| **LiteLLM** ✓ | Chosen | Open source; single endpoint for Claude (Anthropic API) and local Ollama instances; unified rate limiting and retry logic; model alias routing (agents call `claude-3-7-sonnet` or `ollama-judge` without knowing the underlying URL); Helm chart available (`litellm/litellm`); master key authentication keeps the Anthropic API key out of individual agent configs |

---

## Summary: Chosen vs Replaced

| Concern | Initially Considered | Final Choice |
|---|---|---|
| Registry store | PostgreSQL / etcd | Consul KV |
| IDP | Keycloak / Okta | Keycloak (self-hosted) |
| CIBA notification | Twilio | AWS SNS (SMS) + Duo Mobile |
| HITL framework | LangGraph | Claude tool use interrupt (Anthropic native) |
| Runtime security | Falco | GuardDuty (managed) + KubeArmor (enforce) |
| Dynamic policy engine | OPA only | OPA (baseline) + Cedar (dynamic) |
| Policy format for LLM generation | LLM-generated Rego | LLM-generated Cedar (formally verified) |
| Delegation tokens | Macaroons | Biscuits (Ed25519 / SPIFFE key) |
| AWS pod IAM | IRSA | EKS Pod Identity |
| SPIRE attestation | AWS EKS node attestor (aws_iid) | k8s_sat (cloud-agnostic) |
| Tool discovery | Vanilla MCP tools/list | Intent-Aware Tool Catalog |
| DNS | Separate DNS server | CoreDNS + Consul DNS (built-in) |
| Deployment platform | Generic Kubernetes | AWS EKS |
| Authenticator app | Google Authenticator / custom app | Duo Mobile |
| K8s deployment orchestration | Individual helm/kubectl commands | Helmfile |
| Local LLM inference | (not defined) | Ollama (3 isolated instances) |
| Agent framework | LangGraph / Google ADK | Claude API native tool use |
| Tool integrity verification | Source/binary hash | OCI image digest + MCP manifest hash (background CronJob) |
| Prompt injection detection | Regex / keyword list | LLM Guard + Rebuff + arc_pi_taxonomy semantic index |
| Automated red teaming | Manual pen testing | Garak + arc_pi_taxonomy CI/CD suite |
| IaC security scanning | (not defined) | Checkov (GitHub Actions) |
| SIEM / correlation | ELK / Splunk | OpenSearch Security Analytics |
| LLM model proxy | Direct API calls | LiteLLM |
