# Agentic AI Security — Implementation Technology Choices

This document maps each requirement area to concrete technology selections, with rationale and integration notes.

---

## 1. Identity and Authentication

### Workload Identity — SPIFFE / SPIRE

| Component | Technology | Notes |
|---|---|---|
| Workload identity standard | [SPIFFE](https://spiffe.io) | Defines the SVID (SPIFFE Verifiable Identity Document) format |
| Identity runtime | [SPIRE](https://github.com/spiffe/spire) | Issues and rotates SVIDs; supports attestation plugins |
| Token format | **JWT-SVID** or **X.509-SVID** | X.509 preferred for mTLS; JWT for HTTP bearer flows |

Every agent process registers with the SPIRE agent on its node. SPIRE issues a short-lived X.509 or JWT certificate scoped to that workload. No long-lived secrets are stored.

### Identity Provider (IDP)

| Component | Technology | Notes |
|---|---|---|
| IDP | [Keycloak](https://www.keycloak.org) (self-hosted) | Full control, no data egress, CIBA supported since v18 |
| Protocol | OIDC / OAuth 2.0 | Federated identity for human users and service accounts |
| CIBA delivery mode | Poll mode (initial) → Ping mode (production) | Agent polls token endpoint until user approves |
| Authentication Channel Provider (ACP) | Custom FastAPI service | Keycloak calls the ACP; ACP routes to the appropriate notification channel based on user preference |
| Notification channel (primary) | **AWS SNS → SMS** | No app required; phone number stored in Keycloak user attribute |
| Notification channel (rich UX) | **Duo Mobile** via Duo Auth API + Keycloak Duo SPI plugin | Authenticator app with Approve/Deny push; no custom app to build |

**How the CIBA flow works:**

```
1. Agent initiates backchannel auth request
   POST /realms/{realm}/protocol/openid-connect/ext/ciba/auth
   → Keycloak returns: auth_req_id, expires_in, interval

2. Keycloak calls the custom ACP
   POST https://acp.firm.internal/notify
   Body: { user, auth_req_id, binding_message }

3. ACP checks user's preferred notification channel:

   ┌─── Channel: SMS ──────────────────────────────────────────┐
   │  ACP looks up user's phone number from Keycloak           │
   │  Publishes to AWS SNS:                                    │
   │    "Agent action requires approval — [binding_message]    │
   │     Approve: https://auth.firm.internal/ciba/approve?     │
   │     req=auth_req_id"                                      │
   │  User taps link in SMS → Keycloak approval page           │
   └───────────────────────────────────────────────────────────┘

   ┌─── Channel: Duo Mobile ───────────────────────────────────┐
   │  ACP calls Duo Auth API:                                  │
   │    POST /auth/v2/auth                                     │
   │    { username, factor: "push",                            │
   │      pushinfo: "Agent: [binding_message]" }               │
   │  Duo pushes to user's Duo Mobile app                      │
   │  User sees Approve / Deny buttons with binding_message    │
   │  User taps Approve → Duo signals back to ACP              │
   │  ACP notifies Keycloak: auth_req_id approved              │
   └───────────────────────────────────────────────────────────┘

4. Agent polls Keycloak token endpoint with auth_req_id
   → Once approved, Keycloak returns access_token + id_token
```

**Notification channel comparison:**

| Channel | Infrastructure needed | User experience | Best for |
|---|---|---|---|
| **SMS via AWS SNS** | SNS + phone number in Keycloak user profile | Tap link in SMS → browser approval page | Starting point; zero app dependency |
| **Duo Mobile push** | Duo account + Keycloak Duo SPI plugin + Duo Mobile app | Rich push with Approve/Deny + binding message visible in app | Production UX; enterprise teams already using Duo for MFA |
| **Custom FCM/APNs app** | Build iOS/Android app + register with AWS SNS | Fully custom UX | Only if you need a branded in-house app — not recommended when Duo covers the need |

**Why standard authenticator apps (Google Authenticator, Authy, FreeOTP) do not work here:**
These apps generate TOTP codes only — they have no push notification capability and cannot receive or respond to a CIBA approval request. They are useful for step-up MFA but not for the async agent approval flow.

**Recommended rollout:**
1. Start with **SMS via AWS SNS** — works immediately, no app installation required
2. Add **Duo Mobile** for users who want the richer Approve/Deny experience
3. Skip custom FCM/APNs app — Duo replaces it without any app development

### Token Design for Delegation

- Use **Macaroons** for delegated, self-attenuating credentials (see §2.3).
- Alternatively, use **OAuth 2.0 Token Exchange (RFC 8693)** via Keycloak to issue narrowed tokens for sub-agents.
- Sub-agent tokens must contain a `scope` that is a strict subset of the parent's scope and a `sub` (subject) that is the sub-agent's own SPIFFE identity — never the caller's.

---

## 2. Authorization and Least Privilege

### Policy Engine

Policies are **not static**. The policy engine has two layers that work together — a permanent human-written baseline and a dynamic LLM-generated task policy written fresh for every agent invocation.

**Layer 1 — Baseline policies (human-written, permanent)**

| Component | Technology | Notes |
|---|---|---|
| Policy language | [Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) (OPA) | Absolute floor rules — what agents can NEVER do regardless of intent |
| Policy runtime | [Open Policy Agent (OPA)](https://www.openpolicyagent.org) | Evaluated on every request; baseline rules never change without human review |
| Policy distribution | [OPAL](https://github.com/permitio/opal) | Streams baseline policy changes to OPA; changes are Git-reviewed before merge |

Examples of baseline rules: "no agent may call `delete_record` on production data", "no agent may send email to external domains".

**Layer 2 — Dynamic task policies (LLM-generated, task-scoped)**

This is the core of the intent-to-policy requirement. At the start of every agent task, a dedicated **Policy Generation LLM** infers the appropriate constraints from the current intent and writes a Cedar policy scoped to that task. The policy expires automatically when the task ends — no standing permissions.

[Cedar](https://github.com/cedar-policy/cedar) (Apache 2.0, open source) is chosen as the dynamic policy engine because:
- Purpose-built for programmatically generated policies — designed so code (or an LLM) writes policies, not just humans
- Formally verifiable — mathematical proof that a generated policy cannot exceed baseline permissions before it is applied
- Structured, constrained syntax — significantly safer for LLM generation than Rego
- Cloud-agnostic — pure Rust library, runs identically on AWS, GCP, Azure, or on-premises
- No cloud vendor dependency despite AWS origin

| Component | Technology | Notes |
|---|---|---|
| Policy Generation LLM | Local Ollama (Llama 3.1 8B) — isolated, dedicated instance | Separate from the agent LLM; receives intent + context; generates Cedar policy |
| Dynamic policy engine | [Cedar](https://github.com/cedar-policy/cedar) (Apache 2.0) | Evaluates LLM-generated policies; formally verifiable; cloud-agnostic |
| Policy Validator | Cedar's built-in formal verifier | Proves generated policy cannot expand beyond baseline before applying — mathematical guarantee, not just a second LLM check |
| Policy Validator LLM | Second local Ollama instance | Semantic check: does the policy match the declared intent? Catches logic that is valid Cedar but semantically wrong |
| Policy application | Cedar SDK called from gateway | Policy loaded into Cedar engine immediately; tagged with `task_id` + `ttl: task_scope` |
| Policy expiry | Gateway removes Cedar policy on task completion or timeout | Zero standing permissions remain after task ends |

**Dynamic policy generation flow:**

```
User intent: "search public web for Acme Corp Q1 2026 financials"
        │
        ▼
Policy Generation LLM receives:
  { intent, agent_type, baseline_permissions, risk_signals, data_context }
        │
        ▼
Generates Cedar policy for this task:

  // Generated by LLM — scoped to task-8a3f2c1d
  permit(
    principal == AgentType::"web-search-agent",
    action == Action::"invoke",
    resource == Tool::"web_search"
  ) when {
    context.task_id == "task-8a3f2c1d" &&
    context.data_classification == "public"
  };

  // Explicit deny for everything else this task
  forbid(
    principal == AgentType::"web-search-agent",
    action == Action::"invoke",
    resource == Tool::"send_email"
  ) when { context.task_id == "task-8a3f2c1d" };
        │
        ▼
Cedar formal verifier runs BEFORE policy is applied:
  - Proves: generated policy ⊆ baseline permissions
  - Proves: no forbid in baseline is overridden
  - Mathematical guarantee — not runtime inference
  If verification fails → BLOCK + escalate to human via HITL
        │
        ▼
Policy Validator LLM (semantic check):
  - "Does this Cedar policy match the declared intent?"
  - Catches: valid Cedar syntax but wrong intent (e.g. allows wrong tool)
        │
        ▼
Cedar policy loaded into gateway engine — enforced immediately
Tagged: task_id=task-8a3f2c1d, ttl=task_scope
        │
        ▼
Agent executes — Cedar evaluates every tool call against this policy
        │
        ▼
Task ends → gateway removes Cedar policy
→ Zero standing permissions remain
```

**Two-layer enforcement on every tool call:**

```
Tool call arrives at gateway
        │
        ├──► OPA evaluates baseline Rego     → DENY? → Block immediately
        │
        └──► Cedar evaluates task policy     → DENY? → Block immediately
                    │
                  Both ALLOW?
                    │
                    ▼
              Dispatch to tool
```

**Safeguard: Cedar formal verification before apply**

Cedar's verifier proves — before the policy is ever loaded — that no generated policy can grant permissions exceeding the baseline. This is a mathematical proof, not a runtime check. An LLM hallucination that generates an overly permissive Cedar policy is caught at the verification step, never reaches enforcement.

### Self-Attenuating Tokens — Biscuits

[Biscuits](https://github.com/biscuit-auth/biscuit) replace Macaroons as the delegation token format.

**Why Biscuits over Macaroons:**
Macaroons use HMAC (symmetric key) — every verifier must share the root secret with the issuer. Biscuits use **Ed25519 public key cryptography** — verifiers only need the public key. This maps directly onto SPIFFE/SPIRE where each agent already has its own Ed25519 key pair in its SVID. The SPIRE-issued key IS the Biscuit signing key — no separate key management.

| Component | Technology | Notes |
|---|---|---|
| Token format | [Biscuits](https://github.com/biscuit-auth/biscuit) | Public key signed; Authority block + Restriction blocks; Datalog policy facts embedded |
| Signing key | SPIFFE SVID Ed25519 key pair (issued by SPIRE) | No new key management — SPIRE key IS the Biscuit key |
| Library | [biscuit-python](https://github.com/biscuit-auth/biscuit-python) | Python SDK; also available in Rust, Go, Java |
| Verification | Gateway verifies using issuer's SPIFFE public key | No shared secret needed anywhere |

**Biscuit structure for agent delegation:**

```
Authority block (Orchestrator — signed with its SPIRE Ed25519 private key):
  agent("web-search-agent");
  allowed_tools(["web_search", "query_internal_db"]);
  data_ceiling("confidential");
  task("task-8a3f2c1d");

Restriction block added by Orchestrator when delegating to Web Search sub-agent:
  // Caveats narrow — never expand
  check if allowed_tools($t), $t == "web_search";   ← narrowed to 1 tool
  check if data_ceiling($d), $d == "public";         ← narrowed to public only

Gateway verifies:
  - Signature valid against Orchestrator's SPIFFE public key ✓
  - Restriction blocks satisfied ✓
  - Sub-agent cannot exceed what the Authority block granted ✓
  - No root secret shared anywhere ✓
```

**Biscuits + Cedar — complementary layers:**

Biscuits prove **who delegated what and with what restrictions** (the delegation chain).
Cedar proves **what this task's policy permits** (the intent-based policy).
Both must agree on every tool call.

```
Tool call arrives:
  Biscuit check:  is this tool in the delegation chain's allowed scope? → Yes ✓
  Cedar check:    does the task policy permit this tool for this intent?  → Yes ✓
  OPA check:      does the baseline permit this at all?                   → Yes ✓
  → Dispatch
```

### Just-in-Time Trust

- At the gateway layer (§6), every incoming request triggers a fresh OPA evaluation.
- No session-level caching of authorization decisions. Each action is independently authorized.
- OPAL ensures OPA always has up-to-date policy context (e.g., revoked agents, updated intent mappings).

---

## 3. Tool Security and Registry

### Tool Registry

| Component | Technology | Notes |
|---|---|---|
| Registry store | [Consul](https://www.consul.io) KV store | Stores tool metadata; native watch support for OPAL sync; pairs with Vault |
| Image digest | SHA-256 of the tool's **container image** (OCI digest, captured by CI/CD at build time) | What is hashed — not source code; the built and deployed image |
| Manifest hash | SHA-256 of the tool's **MCP `/tools/list` response** (schema/interface contract, captured at registration) | Catches interface tampering even if image digest is unchanged |
| Signing | [Sigstore / Cosign](https://docs.sigstore.dev/cosign/overview/) | CI/CD pipeline signs the container image; gateway verifies the signature bundle |
| Verification | Background verifier (runs every 60s) queries K8s API for live image digest + fetches live manifest; compares both against registry; sets `status = hash_mismatch` on deviation | Gateway fast path checks `status == active` per request — no per-call hashing |

### Tool Protocol

**Why vanilla MCP tool discovery is insufficient:**
Standard MCP loads all tools at session start via `tools/list` — the agent sees every tool the server exposes regardless of the current task. This violates least privilege and widens the prompt injection attack surface (an injected payload can reference any tool the agent knows about).

The solution is to **split discovery from invocation**:
- **MCP is kept for invocation** — structured, typed tool calls over mTLS. It is good at this.
- **`tools/list` is replaced** by an Intent-Aware Tool Catalog that returns only the tools justified by the agent's current intent.

| Component | Technology | Notes |
|---|---|---|
| Tool invocation protocol | [MCP](https://modelcontextprotocol.io) over HTTP with mTLS (SPIFFE X.509) | Used only for invoking tools, not for discovery |
| Tool discovery | **Intent-Aware Tool Catalog** (custom FastAPI service) | Returns a filtered tool manifest based on agent identity + current intent |
| Intent extraction | LLM Judge (local Ollama — Llama 3.1 8B) | Converts free-text intent into structured tags used for tool matching |
| Authorization | OPA query: `agent_type × intent_tags × tool registry` | Returns the permitted tool set for this specific intent at this moment |

**How the Intent-Aware Tool Catalog works:**

```
Agent receives task: "search public web for Acme Corp Q1 2026 financials"
        │
        ▼
Agent calls Tool Catalog:
  POST /catalog/tools
  {
    "agent_id":   "spiffe://firm.internal/agent/web-search/instance-7c3d",
    "intent":     "search public web for Acme Corp Q1 2026 financials",
    "task_scope": "research_acme_q1_2026"
  }
        │
        ▼
Tool Catalog pipeline:
  1. LLM Judge extracts intent tags → [web_search, public_data, read_only]
  2. OPA query: agent_type=web-search-agent + intent_tags → allowed tools
  3. Cross-check Consul tool registry: status == active, allowed_callers match
        │
        ▼
Returns filtered manifest (MCP schema format):
  {
    "tools": [
      { "name": "web_search", "description": "...", "inputSchema": { ... } }
    ]
  }
  ← only 1 tool returned, not the full server list
        │
        ▼
Agent invokes web_search via MCP using this manifest
Gateway enforces: any call to a tool outside this catalog response → blocked
```

**Why this also strengthens prompt injection defence:**
If an injected payload instructs the agent to call `delete_record` or `send_email`, those tools were never in the catalog response for this intent — the agent has no knowledge of them and the gateway blocks any attempt. The attack surface shrinks to only the tools the current intent justifies.

**Manifest hash update:**
The background verifier now hashes the **full server tool list** (all tools the MCP server could ever expose) rather than the filtered catalog response — this detects tampering at the server level. The catalog filters on top of that verified baseline.

### LLM-as-Judge for Tool Calls

| Component | Technology | Notes |
|---|---|---|
| Judge LLM (inference) | [Ollama](https://ollama.com) running **Llama 3.1 8B** or **Mistral 7B** locally | Low latency, no external data egress, cost-effective for high-volume judgments |
| Judge LLM (fallback/complex) | Claude Haiku 4.5 via Anthropic API | For cases where local model confidence is below threshold |
| Agent inference LLM | Claude Sonnet 4.6 or Opus 4.7 via Anthropic API | High-capability model for primary agent reasoning |
| Judge prompt template | Structured prompt: `Given intent: <X>, the agent requested tool: <Y> with args: <Z>. Is this consistent with the intent? Answer yes/no and reason.` | |

The judge runs as a synchronous sidecar call within the gateway. It adds ~100–300 ms latency per tool call using the local model. If the judge returns `no`, the gateway blocks the call and logs the mismatch.

---

## 4. Agent Registry and Tool Registry

These are two distinct, foundational registries. Every other security control — OPA policies, Macaroon scope, gateway verification, SPIRE attestation — draws its source of truth from them.

---

### 4.1 Agent Registry

The Agent Registry is the authoritative catalog of every **approved agent type** that is permitted to run in the system. An agent that is not in the registry cannot obtain a Macaroon from the gateway and cannot be attested by SPIRE.

**What it stores (per agent type):**

| Field | Description | Example |
|---|---|---|
| `agent_type_id` | Unique identifier for this agent type | `web-search-agent` |
| `display_name` | Human-readable name | `Web Search Agent` |
| `description` | Purpose and scope of this agent | `Searches public web; no access to internal data` |
| `spiffe_path_pattern` | SPIFFE ID pattern SPIRE will issue for instances | `spiffe://firm.internal/agent/web-search/*` |
| `allowed_tools` | Exhaustive list of tools this agent type may call | `[web_search]` |
| `max_data_classification` | Highest data sensitivity level this agent may touch | `public` |
| `max_blast_radius` | Risk ceiling (low / medium / high) | `low` |
| `owner_team` | Team responsible for this agent's behavior | `research-platform` |
| `image_digest` | SHA-256 of the agent's **container image digest** (OCI content-addressable digest, captured at CI/CD build time) | `sha256:a3f2...` |
| `status` | `active` / `suspended` / `revoked` | `active` |
| `registered_at` | Timestamp of registration | `2026-04-01T10:00:00Z` |
| `revoked_at` | Populated if status is `revoked` | `null` |

**Technology:**

| Component | Technology | Notes |
|---|---|---|
| Registry store | [Consul](https://www.consul.io) KV store (`agents/*` prefix) | Each agent type is a key; native watch support; ACLs restrict writes to `registry-admin` token only |
| Admin interface | Internal web UI + REST API (FastAPI) backed by Consul HTTP API | Only `registry-admin` role can register or revoke agents |
| OPA data sync | OPAL Consul data source watches `agents/*` prefix; pushes diffs to OPA | Revoked agents are denied within seconds |
| SPIRE integration | Custom SPIRE attestation plugin queries Consul before issuing SVID | Unregistered agent type = no SVID issued |

**Registration flow:**

```
Developer submits agent definition (type, allowed_tools, image_digest)
        │
        ▼
Security team reviews and approves (pull request to registry)
        │
        ▼
Registry admin registers the agent type via API
        │
        ▼
OPAL pushes updated agent data to OPA
        │
        ▼
Agent instances can now obtain SVIDs from SPIRE and Macaroons from gateway
```

**Revocation:**
When an agent is found to be misbehaving, a registry admin sets `status = revoked`. OPAL propagates this to OPA within seconds. Any in-flight SVID is no longer trusted at the gateway. New instances cannot start.

---

### 4.2 Tool Registry

The Tool Registry is the authoritative catalog of every **approved tool** that agents are permitted to call. A tool that is not in the registry cannot be dispatched by the gateway — regardless of what a Macaroon or OPA policy says.

**What it stores (per tool):**

| Field | Description | Example |
|---|---|---|
| `tool_id` | Unique identifier | `web_search` |
| `display_name` | Human-readable name | `Web Search` |
| `description` | What the tool does | `Searches the public web via SerpAPI` |
| `mcp_endpoint` | MCP server URL | `https://tools.firm.internal/web-search` |
| `image_digest` | SHA-256 digest of the tool's container image (OCI content-addressable digest) | `sha256:7c4d...` |
| `manifest_hash` | SHA-256 of the tool's MCP `/tools/list` response (schema/interface contract) | `sha256:a3b1...` |
| `sigstore_bundle` | Cosign signature bundle produced by CI/CD pipeline at image build time | (binary blob) |
| `allowed_callers` | Agent types permitted to call this tool | `[web-search-agent]` |
| `data_classification` | Data sensitivity of tool's inputs/outputs | `public` |
| `blast_radius` | Risk level of the tool's side effects | `low` |
| `rate_limit` | Max calls per agent per minute | `10` |
| `requires_hitl_above` | Risk score threshold that triggers human review | `0.75` |
| `status` | `active` / `deprecated` / `revoked` | `active` |
| `registered_at` | Timestamp | `2026-04-01T10:00:00Z` |

**Technology:**

| Component | Technology | Notes |
|---|---|---|
| Registry store | Consul KV store (`tools/*` prefix) | Same Consul cluster as agent registry; separate key namespace |
| Signing infrastructure | [Sigstore / Cosign](https://docs.sigstore.dev/cosign/overview/) | Tool artifacts signed at CI/CD publish time |
| Hash verification service | Sidecar in gateway | Fetches tool's current endpoint hash, compares to registry |
| OPA data sync | OPAL pushes tool registry to OPA | OPA cross-checks `allowed_callers` on every request |

**What gets hashed for an API endpoint tool:**

A tool is a running service, not a file — you cannot hash the URL. Two artifacts are hashed instead:

| What | How | Protects Against |
|---|---|---|
| **Container image digest** | OCI content-addressable SHA-256 over all image layers. Captured at `docker build` time by CI/CD. | Malicious replacement of the entire service implementation |
| **MCP manifest hash** | SHA-256 of the `/tools/list` JSON response (tool names, input/output schemas). Captured at registration. | Subtle schema tampering — e.g., hidden parameter added to exfiltrate data while image stays the same |

**Verification: two-track design (fast path + background verifier)**

Re-verifying both hashes on every tool call would add unacceptable latency. Instead, verification runs in two tracks:

```
Background Verifier (runs every 60s, independent of requests)
        │
        ├── For each active tool in registry:
        │     1. Query Kubernetes API → get running pod's image digest
        │        GET /api/v1/namespaces/tools/pods?labelSelector=tool=web-search
        │        → spec.containers[0].image = "tools/web-search@sha256:7c4d..."
        │
        │     2. Fetch live MCP manifest → compute SHA-256
        │        GET https://tools.firm.internal/web-search/tools/list
        │
        │     3. Compare both against Tool Registry values
        │        image_digest mismatch → set status = "hash_mismatch" + alert
        │        manifest_hash mismatch → set status = "hash_mismatch" + alert
        │
        └── OPAL propagates status change to OPA immediately

Gateway (per-request, fast path — no re-hashing)
        │
        ├── Step 1: Look up tool in registry → status == "active"?
        │     status = "hash_mismatch" → BLOCK immediately (background already caught it)
        │     status = "active" → proceed
        │
        ├── Step 2: OPA checks allowed_callers
        │
        └── Step 3: Dispatch over mTLS to verified endpoint
```

**At registration time (CI/CD pipeline):**
```
docker build → image digest captured
Cosign signs the image → sigstore_bundle stored in registry
Tool deployed → background verifier captures initial manifest hash
Registry entry written: status = active, image_digest = sha256:7c4d..., manifest_hash = sha256:a3b1...
```

**How this prevents tool substitution attacks:**
An attacker who swaps in a malicious container with the same service name gets a different image digest. The background verifier detects the mismatch within 60 seconds, sets `status = hash_mismatch`, and OPAL propagates this to OPA. All subsequent calls to that tool are blocked at the gateway fast path — no per-call hashing overhead required.

---

### 4.3 How the Two Registries Work Together

```
                    ┌─────────────────────┐
                    │   Agent Registry     │
                    │  (approved agents)   │
                    └────────┬────────────┘
                             │  allowed_tools per agent type
                             ▼
                    ┌─────────────────────┐
                    │    Tool Registry     │
                    │  (approved tools)    │
                    └────────┬────────────┘
                             │  hash, endpoint, allowed_callers
                             ▼
                    ┌─────────────────────┐
                    │        OPA           │◄── OPAL syncs both registries
                    │  (policy engine)     │
                    └────────┬────────────┘
                             │  allow / deny
                             ▼
                    ┌─────────────────────┐
                    │      Gateway         │
                    │  (enforces decision) │
                    └─────────────────────┘
```

- The Agent Registry defines **who can call what**.
- The Tool Registry defines **what exists and whether it is genuine**.
- OPA joins them at evaluation time: an agent can only call a tool if (a) the agent type lists that tool in `allowed_tools` AND (b) the tool lists that agent type in `allowed_callers` — both conditions must be true.
- The Macaroon `allowed_tools` caveat must also agree — all three must be consistent for a call to proceed.

---

## 5. Prompt Injection and Jailbreak Prevention  

### Guardrail Layer

| Component | Technology | Notes |
|---|---|---|
| Input/output scanning | [LLM Guard](https://github.com/protectai/llm-guard) | Open-source; detects prompt injection, PII, toxic content |
| Prompt injection detection | [Rebuff](https://github.com/protectai/rebuff) | Heuristic + LLM-based detection; maintains injection attempt memory |
| Jailbreak detection | LLM Guard `BanTopics` + `PromptInjection` scanners | Configurable topic bans and pattern detection |
| Indirect injection filter | Custom semantic filter using sentence embeddings | Scores retrieved external content against a set of injection signal patterns before passing to agent |

### Semantic Inspection Pipeline

```
External Content (web, tools, docs)
        │
        ▼
  Embedding Model (local — nomic-embed-text via Ollama)
        │
        ▼
  Cosine similarity vs. injection signal library
        │
     Score > threshold?
        │
       Yes ──► Strip / quarantine / alert
        │
       No  ──► Pass to agent context
```

- Injection signal library seeded from [arc_pi_taxonomy](https://github.com/Arcanum-Sec/arc_pi_taxonomy).
- Threshold tunable per data source risk level (web search = stricter than internal DB).

---

## 6. Zero Trust Architecture

### Service Mesh (mTLS between agents)

| Component | Technology | Notes |
|---|---|---|
| Service mesh | [Istio](https://istio.io) or [Linkerd](https://linkerd.io) | Enforces mTLS automatically between agent services |
| Certificate source | SPIRE → Istio integration via [SPIFFE CSI Driver](https://github.com/spiffe/spiffe-csi) | SPIRE issues certs; Istio enforces them |
| Zero trust network policy | Kubernetes `NetworkPolicy` + Istio `AuthorizationPolicy` | Deny-by-default; only explicitly declared traffic paths allowed |

### Dynamic Policy Engine

| Component | Technology | Notes |
|---|---|---|
| Runtime policy evaluation | OPA (as above) | Evaluated on every request; never cached across requests |
| Policy update pipeline | OPAL with Git-backed policy store | Policy changes are version-controlled and auditable |
| Context enrichment | OPA receives runtime context: agent ID, task scope, current intent, time-of-day, data sensitivity labels | Enables fine-grained, context-aware decisions |

---

## 7. Agent Gateway / Firewall

### Gateway Architecture

| Component | Technology | Notes |
|---|---|---|
| API gateway base | [Envoy Proxy](https://www.envoyproxy.io) with custom filters | High-performance; supports WASM/gRPC filter extensions |
| LLM-specific gateway | [LiteLLM Proxy](https://github.com/BerriAI/litellm) | Unified interface to multiple LLM providers; supports rate limiting, cost tracking |
| Gateway orchestration | Custom Python service (FastAPI) | Coordinates OPA, LLM judge, Macaroon verification, audit logging |

### Request Flow Through Gateway

```
Agent Tool Call Request
        │
        ▼
1. Verify mTLS / SPIFFE identity
        │
        ▼
2. Validate Macaroon (scope check)
        │
        ▼
3. OPA policy check (intent × tool × identity)
        │
        ▼
4. LLM-as-Judge (semantic intent match)
        │
        ▼
5. Tool registry hash verification
        │
        ▼
6. Throttle check (rate limiter)
        │
        ▼
7. Human-in-the-loop trigger? (if risk score > threshold)
        │
        ▼
8. Dispatch to tool + emit audit event
```

### Throttling and Human-in-the-Loop

| Component | Technology | Notes |
|---|---|---|
| Rate limiting | Envoy rate limit filter + Redis | Per-agent and per-tool limits |
| Human-in-the-loop | **Claude tool use interrupt pattern** (Anthropic API native) | Claude calls a `request_human_approval` tool; orchestration layer pauses execution and notifies the reviewer |
| HITL notification | AWS SNS (SMS) + Duo Mobile push | Same notification infrastructure already used for CIBA — no additional stack needed |
| HITL resume/cancel | Orchestration layer resumes or cancels the Claude API call based on human response | Approval → continue; Deny → raise exception, log, stop agent |
| Risk scoring | Composite score: data sensitivity + tool blast radius + anomaly signal | Score > configurable threshold causes gateway to inject `request_human_approval` into Claude's tool list |

### RBAC

RBAC covers two distinct principal types — **human users** and **non-human agents** — with different registration paths but a single enforcement point: OPA.

**Human RBAC (Keycloak):**

| Component | Technology | Where registered |
|---|---|---|
| Role definition | Keycloak realm roles (`analyst`, `admin`, `viewer`) | Keycloak admin console |
| Role assignment | Keycloak user → role mapping | Human admin assigns roles in Keycloak |
| Role propagation | Role included as claim in JWT/OIDC token at login | Token carries `roles: ["analyst"]` |
| Enforcement | OPA receives JWT claims as input → evaluates role × tool × data policy | Gateway extracts JWT, passes roles to OPA on every request |

**Non-Human RBAC (Agent Registry → OPA):**

Agents do not log into Keycloak. Their role is defined at **agent type registration** in the Agent Registry (Consul) and resolved at runtime from their SPIFFE ID.

| Component | Technology | Where registered |
|---|---|---|
| Role definition | Agent type entry in Consul (`agents/web-search-agent`) contains `role: "agent-researcher-public"` | Agent Registry (Consul) — set by security team at registration time via FastAPI admin API |
| Role assignment | SPIFFE ID encodes agent type (`spiffe://firm.internal/agent/web-search/...`) | SPIRE issues SVID; agent type is embedded in the path |
| Role resolution | OPA receives SPIFFE ID → strips agent type → looks up role in Agent Registry data (synced by OPAL) | Happens inside OPA at evaluation time, no separate lookup call |
| Enforcement | OPA evaluates: agent role × requested tool × data classification × Macaroon caveats | Same OPA instance handles both human and agent RBAC |

**How OPA joins both:**

```
Human request input to OPA:
{
  "principal_type": "human",
  "user_roles":     ["analyst"],          ← from Keycloak JWT
  "tool":           "query_internal_db",
  "data_class":     "confidential"
}

Agent request input to OPA:
{
  "principal_type": "agent",
  "spiffe_id":      "spiffe://firm.internal/agent/web-search/instance-7c3d",
  "agent_type":     "web-search-agent",   ← parsed from SPIFFE ID
  "agent_role":     "agent-researcher-public",  ← looked up from Agent Registry via OPAL
  "tool":           "web_search",
  "data_class":     "public"
}
```

OPA Rego policy (simplified):
```rego
# Human: analyst can query internal DB up to confidential level
allow {
    input.principal_type == "human"
    input.user_roles[_] == "analyst"
    input.tool == "query_internal_db"
    input.data_class in ["internal", "confidential"]
}

# Agent: researcher-public role can only call web_search on public data
allow {
    input.principal_type == "agent"
    input.agent_role == "agent-researcher-public"
    input.tool == "web_search"
    input.data_class == "public"
}
```

**Summary of where roles are registered:**

| Principal | Role registered in | Resolved via | Enforced by |
|---|---|---|---|
| Human user | Keycloak (admin console) | JWT claim in OIDC token | OPA |
| Agent (non-human) | Agent Registry in Consul (at agent type registration) | SPIFFE ID → agent type → OPAL-synced data in OPA | OPA |

---

## 8. Audit, Observability, and Accountability

### Distributed Tracing

| Component | Technology | Notes |
|---|---|---|
| Tracing standard | [OpenTelemetry](https://opentelemetry.io) (W3C Trace Context) | Propagated across every agent-to-agent and agent-to-tool call |
| Trace backend | [Jaeger](https://www.jaegertracing.io) or [Tempo](https://grafana.com/oss/tempo/) | Full trace graph from user intent to leaf tool calls |
| Span attributes | `agent.id`, `intent.id`, `tool.name`, `policy.decision`, `macaroon.caveats` | Intent ID links every downstream span back to the originating user action |

### Audit Logging

| Component | Technology | Notes |
|---|---|---|
| Log pipeline | [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) → [Loki](https://grafana.com/oss/loki/) or Elasticsearch | Structured JSON logs with intent lineage |
| Tamper evidence | Append-only log store + periodic hash chaining | Detects log tampering |
| Dashboards | [Grafana](https://grafana.com) | Real-time views of agent activity, policy decisions, anomalies |

### Intent Lineage Model

Every event carries:
- `intent_id`: UUID generated at the point of the original user request
- `agent_id`: SPIFFE ID of the acting agent
- `parent_intent_id`: for sub-agent calls, links to the delegating agent's intent
- `action`: tool name + arguments (redacted for sensitive params)
- `policy_decision`: allow/deny + OPA rule matched

---

## 9. Posture and Threat Management

### Red Teaming

| Component | Technology | Notes |
|---|---|---|
| LLM red teaming framework | [Garak](https://github.com/leondz/garak) | Automated probing for prompt injection, jailbreaks, data leakage |
| Prompt injection test suite | [arc_pi_taxonomy](https://github.com/Arcanum-Sec/arc_pi_taxonomy) | Seed Garak with known injection patterns from this taxonomy |
| Adversarial test runner | CI/CD pipeline job (GitHub Actions) | Runs red team suite on every agent/guardrail change |

### Runtime Threat Detection

| Component | Technology | Notes |
|---|---|---|
| Anomaly detection | Statistical baseline on tool call frequency + sequence patterns | Alert on deviation (e.g., agent calling unusual tool sequence) |
| Behavioral analytics | [Falco](https://falco.org) (extended for LLM workloads) | Runtime syscall and network anomaly detection at container level |
| SIEM integration | OpenTelemetry logs → Elasticsearch → [OpenSearch Security Analytics](https://opensearch.org/docs/latest/security-analytics/) | Correlation rules for multi-step attack patterns across agents |

### Posture Checks

| Component | Technology | Notes |
|---|---|---|
| Configuration scanning | [Checkov](https://www.checkov.io) | Scans IaC (Terraform/Helm) for security misconfigurations |
| Policy coverage gap analysis | Custom OPA query: enumerate all agent × tool pairs not covered by any policy | Run as a scheduled job |
| Tool registry drift detection | Scheduled job comparing live tool hashes against registry | Alerts on any unregistered or hash-mismatched tool |
| CNAPP alignment | Align posture checks with **CNAPP 2.0** framework: cloud + runtime + AI workload coverage | Treat agent workloads as a new resource type in the CNAPP model |

---

## 10. Infrastructure and Deployment

| Layer | Technology |
|---|---|
**Platform: AWS EKS (Elastic Kubernetes Service)**

AWS is the deployment target — AWS SNS is already in the stack, and EKS keeps everything consistent within one cloud.

### EKS Cluster Layout

| Node Group | Instance Type | Purpose |
|---|---|---|
| System nodes | `t3.medium` | Kubernetes system pods, CoreDNS, Consul, OPAL |
| Application nodes | `m5.2xlarge` | Agent workloads, Keycloak, OPA, gateway, Vault |
| GPU nodes | `g4dn.xlarge` | Ollama (LLM judge + embedding model) — GPU required for acceptable latency |
| Observability nodes | `m5.xlarge` | Jaeger, Loki, Grafana, OpenTelemetry Collector |

### AWS Services Used

| AWS Service | Role in stack | Replaces / Complements |
|---|---|---|
| **EKS** | Managed Kubernetes control plane | Self-managed K8s |
| **ECR** (Elastic Container Registry) | Container image registry; integrates with Sigstore/Cosign for image signing | Generic registry |
| **AWS KMS** | Vault auto-unseal key; no manual unseal on pod restart | Manual Vault unseal |
| **EKS Pod Identity** | Grants EKS pods scoped AWS IAM permissions to call SNS, ECR, KMS — AWS's recommended approach over IRSA | No OIDC provider setup; role association managed in EKS directly via `eks:CreatePodIdentityAssociation`; Pod Identity Agent DaemonSet vends credentials to pods via local endpoint |
| **AWS SNS** | CIBA approval notifications + HITL reviewer notifications | Already in stack |
| **AWS ALB** (Application Load Balancer) | External ingress for Keycloak and the analyst portal | Istio ingress gateway handles internal; ALB handles external |
| **VPC + Private Subnets** | All agent and infrastructure pods run in private subnets; no direct internet exposure | Public subnet only for ALB |
| **AWS CloudTrail** | Audits all AWS API calls (SNS publishes, ECR pulls, KMS operations) | Complements OpenTelemetry for AWS-layer audit |

### SPIRE on EKS — Kubernetes Native Attestation

SPIRE uses the **`k8s_sat` (Kubernetes Service Account Token) attestor** — cloud-agnostic, works identically on EKS, GKE, AKS, or on-premises Kubernetes. No AWS-specific dependency is introduced into the identity layer.

The AWS EKS node attestor (`aws_iid`) was considered but rejected: it ties workload identity to EC2 instance identity documents, creating vendor lock-in in a core security component. If the cluster moves clouds or runs locally for dev/staging, the attestation mechanism would need to be rearchitected.

```
SPIRE Server
    │
    └── Node attestor:     k8s_sat
          Kubernetes API server issues a projected service account token
          scoped to a specific audience (the SPIRE server)
          SPIRE verifies the token cryptographically with the K8s API server
          │
    └── Workload attestor: k8s
          Identifies the pod by: namespace + service account + pod labels
          e.g. namespace=agents, serviceaccount=web-search-agent
          → SPIRE issues SVID: spiffe://firm.internal/agent/web-search/...
```

SPIRE entry for the Web Search Agent:
```
spiffe_id:    spiffe://firm.internal/agent/web-search
parent_id:    spiffe://firm.internal/k8s-node
selectors:
  - k8s:ns:agents
  - k8s:sa:web-search-agent
  - k8s:pod-label:app:web-search
```

### Vault on EKS — AWS KMS Auto-Unseal

```
Vault pod starts
    │
    ▼
Vault calls AWS KMS (via IRSA — no stored credentials)
    │
    ▼
KMS decrypts the Vault unseal key
    │
    ▼
Vault unseals automatically — no human operator needed on restart
```

### Infrastructure as Code

| Component | Technology | Notes |
|---|---|---|
| Container runtime | containerd (EKS default) | |
| Orchestration | **AWS EKS** | Managed control plane; worker nodes in private VPC subnets |
| Service mesh | Istio (deployed via Helm on EKS) | mTLS between all pods; works alongside SPIRE |
| Secrets management | HashiCorp Vault on EKS + **AWS KMS** for auto-unseal | |
| Container registry | **AWS ECR** + Sigstore/Cosign image signing | ECR lifecycle policies for image retention |
| CI/CD | **GitHub Actions** + ECR push + Cosign sign | Build → sign → push → deploy |
| IaC | **Terraform** (EKS cluster, VPC, IAM, KMS) + **Helm** (application deployments) | Terraform manages AWS infra; Helm manages K8s workloads |
| Local LLM runtime | Ollama on GPU node group (`g4dn.xlarge`) | Llama 3.1 8B for LLM judge; nomic-embed-text for embeddings |
| Cloud LLM | Anthropic API — Claude Sonnet 4.6 (agent inference), Haiku 4.5 (fallback judge) | Called from agent pods via internet egress through NAT Gateway |

### DNS

No additional DNS server is required. Two layers already in the stack cover all resolution needs:

| Layer | Technology | Resolves |
|---|---|---|
| Cluster-internal service DNS | **CoreDNS** (built into Kubernetes) | `tools.firm.internal`, `auth.firm.internal`, `acp.firm.internal` → Kubernetes Service ClusterIPs |
| Service registry DNS | **Consul DNS interface** (port 8600) | `web-search.service.consul`, `internal-db.service.consul` → tool pod IPs via Consul service catalog |

CoreDNS is configured to forward `*.consul` queries to Consul DNS with a single ConfigMap entry:

```yaml
# CoreDNS ConfigMap addition
consul:53 {
    errors
    cache 10
    forward . consul.consul-server.svc.cluster.local:8600
}
```

**Note — SPIFFE trust domain is not a DNS name:** The `firm.internal` in SPIFFE IDs (`spiffe://firm.internal/agent/...`) is a trust domain identifier only. SPIRE never performs DNS resolution on it. Identity verification is done against the X.509 certificate URI SAN, not DNS.

**If workloads run outside Kubernetes** (VMs, developer laptops) and need to resolve `*.firm.internal` names, add a lightweight standalone **CoreDNS** or **Unbound** instance on the internal network. No full BIND server required.

---

## 11. Technology Summary by Requirement

| Requirement | Primary Technology |
|---|---|
| Deployment platform | AWS EKS (private VPC subnets) + AWS ALB (external ingress) |
| Container registry | AWS ECR + Sigstore/Cosign image signing |
| Secrets unsealing | HashiCorp Vault + AWS KMS auto-unseal |
| AWS IAM for pods | EKS Pod Identity — scoped per workload, no OIDC provider required |
| IaC | Terraform (AWS infra) + Helm (K8s workloads) |
| Workload identity (non-human) | SPIFFE / SPIRE with `k8s_sat` attestor (cloud-agnostic, K8s API server token verification) |
| IDP + CIBA | Keycloak (self-hosted) + AWS SNS (SMS) + Duo Mobile (push) for CIBA notification delivery |
| Self-attenuating delegation | Biscuits (Ed25519, public key) — signing key = SPIFFE SVID from SPIRE |
| Policy engine (baseline) | OPA + OPAL — permanent human-written Rego floor rules |
| Policy engine (dynamic) | Cedar (Apache 2.0) — LLM-generated Cedar policies, formally verified before apply, task-scoped, auto-expires |
| Zero trust network | Istio mTLS + K8s NetworkPolicy |
| Agent registry | Consul KV (`agents/*`) + FastAPI admin API + OPAL sync to OPA |
| Tool registry + integrity | Consul KV (`tools/*`) + Sigstore/Cosign + SHA-256 |
| Tool discovery | Intent-Aware Tool Catalog (FastAPI) + OPA + LLM Judge |
| Tool invocation | MCP over mTLS (SPIFFE X.509) |
| LLM-as-judge (local) | Ollama + Llama 3.1 8B |
| LLM agent inference | Claude Sonnet 4.6 / Opus 4.7 |
| Prompt injection detection | LLM Guard + Rebuff |
| Semantic injection filter | Sentence embeddings (nomic-embed-text) + arc_pi_taxonomy |
| Agent gateway / firewall | Envoy + FastAPI orchestrator + LiteLLM |
| Throttling | Envoy rate limit + Redis |
| Human-in-the-loop | Claude tool use interrupt pattern (Anthropic API) + AWS SNS / Duo Mobile notification |
| Distributed tracing | OpenTelemetry + Jaeger |
| Audit logging | OpenTelemetry Collector + Loki + Grafana |
| Red teaming | Garak + arc_pi_taxonomy |
| Runtime threat detection | Falco + OpenSearch Security Analytics |
| Posture / config scanning | Checkov + custom OPA gap analysis |

---

## 12. References

- [Biscuit Auth — Public Key Bearer Tokens](https://github.com/biscuit-auth/biscuit)
- [Biscuit Specification](https://www.biscuitsec.org)
- [Cedar Policy Language — Open Source (Apache 2.0)](https://github.com/cedar-policy/cedar)
- [Cedar Policy Specification](https://docs.cedarpolicy.com)
- [Consul — HashiCorp Service Mesh and KV Store](https://www.consul.io)
- [Duo Auth API — Push Notification for CIBA ACP](https://duo.com/docs/authapi)
- [Keycloak Duo SPI Plugin](https://github.com/mths0x5f/keycloak-duo-spi)
- [SPIFFE/SPIRE](https://spiffe.io)
- [Open Policy Agent](https://www.openpolicyagent.org)
- [OPAL — Open Policy Administration Layer](https://github.com/permitio/opal)
- [Macaroons paper](https://research.google/pubs/macaroons-cookies-with-contextual-caveats-for-decentralized-authorization-in-the-cloud/)
- [Model Context Protocol (MCP)](https://modelcontextprotocol.io)
- [LLM Guard](https://github.com/protectai/llm-guard)
- [Rebuff](https://github.com/protectai/rebuff)
- [Garak — LLM Red Teaming](https://github.com/leondz/garak)
- [Ollama](https://ollama.com)
- [LiteLLM Proxy](https://github.com/BerriAI/litellm)
- [Sigstore / Cosign](https://docs.sigstore.dev/cosign/overview/)
- [OAuth 2.0 Token Exchange — RFC 8693](https://datatracker.ietf.org/doc/html/rfc8693)
- [Anthropic Tool Use — Claude API](https://docs.anthropic.com/en/docs/build-with-claude/tool-use)
- [Falco Runtime Security](https://falco.org)
