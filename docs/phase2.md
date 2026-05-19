# Phase 2 — Component Guide

This document explains every Helm release in `helmfile/phase2/helmfile.yaml.gotmpl` — what it does, why it's there, and how it connects to the rest of the system.

---

## Deploy Order

```
ollama-judge ──┐
ollama-policy  │  (deploy in parallel)
ollama-embed ──┤
               ↓
             opal ──► tool-catalog ──► security-gateway ──► injection-signals
                                                          └─► ciba-acp
                   └─► hash-verifier

litellm  (independent — no dependencies)
```

---

## External Charts

### `ollama-judge` · `ollama-policy` · `ollama-embed`
**Chart:** `ollama/ollama`

Three separate Ollama instances, each serving a different model. They are isolated so a slow inference call on one does not block the others.

| Instance | Model | Used by |
|---|---|---|
| `ollama-judge` | `llama3.1:8b` | Security Gateway — checks if a tool call is semantically aligned with the agent's declared intent |
| `ollama-policy` | `llama3.1:8b` | Cedar policy engine — generates and validates task-scoped Cedar policies |
| `ollama-embed` | `nomic-embed-text` | Security Gateway sidecar — generates vector embeddings for real-time prompt injection detection |

Running on CPU (no GPU node required). `llama3.1:8b` needs ~6 GB RAM — values files request 6 Gi and limit at 8 Gi. Model pull takes ~10 min on first deploy; the `ollama-wait-models.sh` hook waits up to 10 min before marking the release complete.

---

### `opal`
**Chart:** `permitio/opal`

OPAL keeps OPA's data in sync with Consul in real time. Without it, OPA holds a static snapshot — if you revoke an agent in Consul, OPA would not know until a manual reload.

OPAL Server watches two Consul KV paths:
- `agents/*` — agent registry (roles, allowed tools, status)
- `tools/*` — tool registry (endpoints, allowed callers, data classification, blast radius)

OPAL Client pushes any change to OPA via the bundle endpoint within 1–2 seconds. The `opal-verify-sync.sh` hook confirms this by writing a test revocation to Consul and checking OPA reflects it within 15 seconds.

---

### `litellm`
**Chart:** `oci://ghcr.io/berriai/litellm-helm`

A unified model proxy. Agents do not call Claude or Ollama directly — they call LiteLLM, which routes to the right model. This gives:
- A single place to manage API keys
- Rate limiting per model
- Automatic fallback (if Claude is unavailable, fall back to local Ollama)
- Model aliasing (agents reference `claude-sonnet-4-6` or `ollama-judge` by name — no hardcoded URLs)

---

## Custom Charts

### `tool-catalog`
**Chart:** `./charts/tool-catalog`

Replaces the raw MCP `tools/list` call. When an agent asks "what tools can I use for this intent?", the catalog:
1. Queries OPA for the agent's baseline allowed tools (by agent type + role)
2. Passes the intent + candidate tools to `ollama-judge` for semantic filtering
3. Returns only tools that are both policy-allowed and intent-justified

Example: a web search agent with intent "search public web" gets back `[web_search]` — never `send_email` or `query_internal_db`, even if OPA would technically allow them for its role.

---

### `security-gateway` (Phase 1 upgrade)
**Chart:** `./charts/security-gateway` · **Image tag:** `phase2`

Same gateway as Phase 1 but the Phase 2 image adds three new enforcement layers:

| Addition | What it does |
|---|---|
| **Cedar** | Task-scoped policies — tools are tied to specific `task_id` values, not just agent roles |
| **Biscuit tokens** | Cryptographic delegation proofs derived from SPIRE SVIDs — the gateway verifies each agent can only call tools explicitly listed in its Biscuit |
| **LLM Guard + Rebuff** | Scans every prompt and tool input for injection patterns using both rule-based (LLM Guard) and semantic (Rebuff + `ollama-embed`) detection |

The `biscuit-key-bootstrap.sh` hook extracts SPIRE SVID private keys from each agent pod and registers them as Biscuit signing keys in the gateway after deploy.

The gateway also mounts the `injection-signals-pvc` PVC at `/data` — the semantic injection index lives there.

---

### `injection-signals`
**Chart:** `./charts/injection-signals`

Not a running service. This chart deploys a single ConfigMap (`injection-build-scripts`) containing a Python script. The `build-injection-signals.sh` hook then:
1. Creates the `injection-signals-pvc` PVC (1 Gi)
2. Runs a one-shot Kubernetes Job that:
   - Clones `github.com/Arcanum-Sec/arc_pi_taxonomy` (a public prompt injection taxonomy)
   - Generates `nomic-embed-text` embeddings for every known injection pattern via `ollama-embed`
   - Saves the index to `/data/injection_signals.pkl` on the PVC

The gateway sidecar loads this pickle at startup. On every tool input, it embeds the text and computes cosine similarity against the index. Similarity > 0.70 (web content) or > 0.85 (internal content) triggers a block.

---

### `ciba-acp` (Phase 1 upgrade)
**Chart:** `./charts/ciba-acp` · **Image tag:** `phase2`

Same CIBA approval service as Phase 1, upgraded with Duo Mobile push via the Keycloak Duo SPI. Phase 1 only sent SMS via AWS SNS.

Phase 2 behaviour:
- If the user has `preferred_channel=duo` set and is enrolled in Duo Mobile → sends an in-app Approve / Deny push with the binding message
- Falls back to SMS via SNS if Duo fails or the user is not enrolled

Duo credentials are injected from the `duo-credentials` Kubernetes secret (synced from Vault by `02_deploy_phase2.sh`).

---

### `hash-verifier`
**Chart:** `./charts/hash-verifier`

A CronJob that runs every 60 seconds. For each registered tool in Consul it:
1. Fetches the live OCI image digest from the registry
2. Fetches the live MCP manifest hash from the tool endpoint
3. Compares both against the expected values stored in Consul

On mismatch, it sets `tools/<name>.status = hash_mismatch` in Consul. OPAL picks up the change within 2 seconds and pushes it to OPA. The gateway's next call to that tool is blocked before dispatch.

This closes the supply-chain attack vector: a compromised or swapped tool image cannot serve requests without detection within 60 seconds.

---

## Values Files Reference

| File | Controls |
|---|---|
| `values/ollama-judge.yaml` | CPU resources (6 Gi RAM), model = `llama3.1:8b` |
| `values/ollama-policy.yaml` | CPU resources (6 Gi RAM), model = `llama3.1:8b` |
| `values/ollama-embed.yaml` | CPU resources (2 Gi RAM), model = `nomic-embed-text` |
| `values/opal.yaml` | Consul KV paths to watch, OPA endpoint |
| `values/tool-catalog.yaml` | OPA + Ollama judge + Consul URLs |
| `values/security-gateway.yaml` | Phase 2 feature flags, injection signals PVC mount |
| `values/ciba-acp.yaml` | `DUO_ENABLED=true`, `duo-credentials` secret ref |
| `values/hash-verifier.yaml` | CronJob schedule (`*/1 * * * *`), Consul URL |
| `values/litellm.yaml` | Model list — Claude Sonnet 4.6, ollama-judge, ollama-policy |
| `values/injection-signals.yaml` | Ollama embed URL, PVC size |

---

## Hook Scripts Reference

| Script | Runs after | What it does |
|---|---|---|
| `ollama-wait-models.sh` | Each Ollama release | Waits up to 10 min for the model pull to complete |
| `opal-verify-sync.sh` | `opal` | Writes a test revocation to Consul, confirms OPA reflects it in < 15s |
| `biscuit-key-bootstrap.sh` | `security-gateway` | Extracts SPIRE SVID keys from agent pods, registers as Biscuit signing keys |
| `build-injection-signals.sh` | `injection-signals` | Creates PVC, runs embedding Job, waits for completion |

---

## References

- [OPAL documentation](https://docs.opal.ac)
- [Ollama Helm chart](https://github.com/otwld/ollama-helm)
- [LiteLLM](https://github.com/BerriAI/litellm)
- [Biscuit Auth](https://github.com/biscuit-auth/biscuit)
- [Cedar Policy Language](https://github.com/cedar-policy/cedar)
- [LLM Guard](https://github.com/protectai/llm-guard)
- [arc_pi_taxonomy](https://github.com/Arcanum-Sec/arc_pi_taxonomy)
- [Duo Auth API](https://duo.com/docs/authapi)
