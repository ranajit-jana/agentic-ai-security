# CIBA — Client-Initiated Backchannel Authentication

## What Is CIBA?

**Client-Initiated Backchannel Authentication (CIBA)** is an OAuth 2.0 / OpenID Connect extension defined by the OpenID Foundation ([spec](https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html)). It decouples the authentication and consent act from the user's current browser session.

In classic OAuth 2.0, the user must be present at a browser redirect — the client redirects the user to an authorization server, the user logs in and consents, and the browser bounces back with a code. This works for web apps but breaks completely for background processes that have no browser, no active session, and no way to redirect anyone anywhere.

CIBA solves this by introducing an **Authentication Channel Provider (ACP)** — an out-of-band delivery path (SMS, push notification, email) that reaches the user on whatever device they choose, entirely independent of the client making the request.

---

## The Three Parties

| Role | Description |
|---|---|
| **Client** | The system requesting authentication — in agentic contexts this is the AI agent or orchestrator |
| **Authorization Server** | The Identity Provider (Keycloak in this project) that manages the CIBA flow and issues tokens |
| **Authentication Channel Provider (ACP)** | A service that delivers the approval request to the user's device (SMS via AWS SNS, push via Duo Mobile) |

---

## How the Flow Works

```
Agent                    Keycloak                       ACP                    User's Device
  │                           │                          │                          │
  │  POST /ciba/auth          │                          │                          │
  │  (login_hint, scope,      │                          │                          │
  │   binding_message)        │                          │                          │
  ├─────────────────────────► │                          │                          │
  │                           │                          │                          │
  │ ◄─── auth_req_id  ────────┤                          │                          │
  │       expires_in          │                          │                          │
  │       interval            │                          │                          │
  │                           │  POST /notify            │                          │
  │                           │  (user, auth_req_id,     │                          │
  │                           │   binding_message)       │                          │
  │                           ├────────────────────────► │                          │
  │                           │                          │  SMS / Push              │
  │                           │                          ├────────────────────────► │
  │                           │                          │                          │
  │  Poll token endpoint      │                          │   User taps Approve      │
  │  (auth_req_id)            │                          │ ◄──────────────────────  │
  ├─────────────────────────► │ ◄────────── approval ─── ┤                          │
  │                           │                          │                          │
  │ ◄─── access_token ─────── ┤                          │                          │
  │       id_token            │                          │                          │
```

### Identifying the User

The CIBA request must tell the authorization server which user to contact. Three hint formats are supported — exactly one must be provided:

| Hint | Format | When to use |
|---|---|---|
| `login_hint` | Plain identifier — email, username, phone number | Most common; simplest to implement |
| `login_hint_token` | Signed JWT in a deployment-specific format | When the user's real identifier must not appear in the request (privacy) |
| `id_token_hint` | A previously issued OIDC ID token for that user | When the client already holds a token from a prior session |

In this project the orchestrator uses `login_hint` with the analyst's email address, stored in Keycloak's user attribute `phone_number` to drive SNS delivery.

### Step-by-step

1. **Agent initiates** — posts a backchannel auth request to Keycloak, specifying `login_hint` (which user to notify), requested scopes, and a human-readable `binding_message` describing what is about to happen.
2. **Keycloak responds immediately** with an `auth_req_id`, a TTL (`expires_in`), and a polling `interval`. The agent stores this and continues (or pauses, depending on risk score).
3. **Keycloak calls the ACP** — the custom FastAPI ACP service receives the notification payload and routes it to the user's preferred channel (SMS via AWS SNS, or a Duo Mobile push).
4. **User receives the approval request** on their device, reviews the `binding_message`, and taps Approve or Deny.
5. **Agent polls the token endpoint** with the `auth_req_id` at the specified interval. Once the user approves, Keycloak responds with an access token and ID token. If denied or expired, it returns an error the agent handles gracefully.

---

## Polling Modes

CIBA defines three delivery modes. This project implements:

| Mode | How it works | Used when |
|---|---|---|
| **Poll** (implemented) | Client polls the token endpoint repeatedly at `interval` seconds until a token or error is returned | Default; simple, no webhook infra needed |
| **Ping** (planned for production) | Keycloak calls a client-registered callback URL when the user responds; client fetches the token once | Lower latency; avoids polling overhead at scale |
| **Push** | Keycloak pushes the token directly to the client callback | Not used — creates complexity managing token delivery at the client |

---

## Classic Use Cases — The Protocol's Non-Agent Origins

CIBA was not invented for AI. Understanding where it came from makes its value in agentic systems much clearer.

### Call Center Authentication

A customer calls a bank. The agent at the call center looks up the account and needs to perform a sensitive transaction. Under the old model, the agent asks the customer to recite their password or PIN over the phone — credentials travel through a channel the bank cannot control. With CIBA:

1. The call center operator initiates a CIBA request for the caller's account.
2. The customer receives a push notification on their registered mobile app.
3. The customer authenticates on their own device using biometrics (Face ID, fingerprint) — nothing is spoken aloud.
4. The call center agent receives a token confirming authentication and proceeds.

The customer never shares their credentials. The call center agent never sees them. The authentication happened on hardware the customer trusts.

### Point of Sale — Retail Pickup

A customer orders online and picks up in-store. The POS terminal initiates a CIBA request at checkout. The customer's phone receives a notification and they approve with a fingerprint. The terminal gets a token; the transaction proceeds. No card swipe, no PIN pad — just the customer's own device as the authenticator.

### Face-to-Face — Banking / Healthcare

A teller or clinician is seated at a workstation and a customer/patient is across the desk. The staff member initiates a CIBA request. The customer authenticates on their own phone. Staff never holds the customer's credentials and the customer's authentication stays on their device.

**The common thread**: in all of these, one party (the operator, the terminal, the agent) initiates a flow, and a separate party (the human) authenticates on their own device, in their own time, without ever handing credentials to the initiating party. This is exactly the pattern that makes CIBA the right fit for agentic systems.

---

## Why Is CIBA Needed?

### The Core Problem: Agents Are Headless

Traditional OAuth assumes a human sits at a browser. AI agents are background processes — they run inside Kubernetes pods, have no browser, and cannot initiate a redirect flow. When an agent needs a human to approve a high-risk action, there is no standard mechanism in OAuth 2.0 / OIDC to request that approval asynchronously.

CIBA was designed precisely for this gap. It is the only standardized protocol that allows a non-interactive client to request human authentication and consent through an out-of-band channel, then receive a token once the human responds.

### Why Not Just Use an API Key or Service Account?

Service accounts and API keys represent the **agent's** identity, not the **human's** approval. They cannot express "a human reviewed this specific action and consented." CIBA tokens are tied to the specific `auth_req_id` and carry the human's authenticated identity in the ID token — providing cryptographic proof of human approval for that exact request.

### Why Not a Custom Webhook or Internal Flag?

Custom approval webhooks are not auditable by external parties and are not standardized. Any internal flag ("approved = true in a database row") can be set by the system itself — there is no separation of duty. CIBA flows through an external IDP (Keycloak), which means the approval is recorded at the authorization server, independent of the agent, and verifiable via the token's claims.

### Financial-Grade Pedigree

CIBA is adopted by the **FAPI 2.0 Security Profile** (Financial-grade API), the standard used by open banking regulations in the UK, EU, and Brazil. Financial regulators explicitly require it for flows where a third-party app initiates an action on a bank account. That pedigree means the protocol has been adversarially reviewed for exactly the kinds of threats that matter in agentic systems: replay, token substitution, approval without user knowledge, and credential interception.

---

## Benefits in Agentic Systems

### 1. Human-in-the-Loop Without Blocking the Agent

CIBA is asynchronous. The agent requests approval and either polls quietly in the background or suspends its task graph. The human receives a notification on their own device and responds on their own schedule (within the TTL). The agent resumes only when a valid token is received. There is no need for a shared UI, no need for the human to be logged into the same system, and no blocking synchronous call.

### 2. Cryptographic Proof of Human Intent

The access token returned after CIBA approval is a standard JWT signed by Keycloak. It contains the human's `sub` (subject), the approved scopes, and a timestamp. The agent attaches this token to the action it was approved to take. Downstream systems — the security gateway, OPA, audit log — can verify the token's signature and confirm that a specific human approved a specific scope at a specific time. This is not a flag in a database; it is a signed, verifiable assertion.

### 3. Binding Message Ties Approval to Intent

The `binding_message` field in the CIBA request is shown verbatim to the user in the approval notification. For example:

```
"Approve: Send quarterly report to board@firm.com via the Email Agent — includes revenue figures classified CONFIDENTIAL."
```

The user approves this exact description, not a vague "agent wants permission." This prevents escalation attacks where the agent requests broad approval for a narrowly described action, and it closes the gap between what the user thinks they approved and what the agent actually does.

### 4. Out-of-Band Delivery Is Phishing-Resistant and Supports Biometrics

Because the approval arrives on a separate device (phone via SMS or push) from the one running the agent, a compromised agent session cannot silently auto-approve its own requests. An attacker who compromises the agent pod cannot approve its own CIBA requests — the approval channel is the user's phone, not a browser cookie the attacker already has.

Beyond channel separation, the user's authentication on their device can use an **inherence factor** — Face ID, Touch ID, a device PIN — rather than a password. This means the approval is bound to something the user physically possesses and biometrically controls. No password is typed, transmitted, or interceptable during the approval flow.

### 5. Standard Protocol — Auditable and Interoperable

CIBA is an OpenID Foundation standard. Every CIBA event generates standard OAuth 2.0 token endpoint logs at Keycloak. These logs are independent of the agent's own audit trail and can be compared — if the agent claims it had approval, the Keycloak logs either confirm or contradict it. No custom logic is needed to audit approvals.

### 6. Composable with the Broader Zero-Trust Stack

CIBA tokens are just JWTs. They compose naturally with the rest of the security stack in this project:

- The **security gateway** validates the CIBA token signature and checks that the approved scopes match the tool being invoked.
- **OPA Rego policies** can reference the token's claims (human identity, approved scopes, approval timestamp) as policy inputs.
- **Cedar dynamic policies** can require a valid CIBA token as a precondition for high-risk tool execution.
- **OpenTelemetry traces** attach the `auth_req_id` as a span attribute, linking every downstream action back to the specific human approval event.
- **Biscuit delegation tokens** can be restricted to only forward the CIBA-approved scope to sub-agents, preventing privilege escalation across agent hops.

### 7. Eliminates Credential Sharing

Without CIBA, the only way for a background process to prove human authorization is to hold the human's credentials (password, OTP, session cookie) and replay them. This forces the human to hand credentials to the agent — the agent becomes a credential store, a high-value target, and a single point of compromise.

CIBA removes this entirely. The human never hands anything to the agent. The agent receives only a token asserting "user X approved scope Y at time T" — the credential that generated that approval never leaves the user's device.

### 8. Risk-Threshold Gating

Not every agent action requires CIBA approval. The security gateway computes a composite risk score per tool call (data sensitivity + tool blast radius + anomaly signal). Only actions above a configurable threshold trigger a CIBA request. Low-risk reads proceed without interruption; high-risk writes, external communications, or access to sensitive data classes pause for human sign-off. CIBA is the mechanism that makes this selective gating possible without requiring the human to be present for every call.

---

## CIBA in the Sarah Use Case

CIBA has a single trigger point in the analyst use case: **Step 8 — when the Email Agent attempts to send a confidential document externally**. Step 5 (`query_internal_db`) is elevated risk (0.65) but stays below the CIBA threshold — it is read-only, stays internal, and is covered by compensating controls. Every other step runs at low risk or is blocked by a different control (Macaroon scope, LLM Judge).

### Where Each Actor Stands

| Actor | Role in the CIBA Flow |
|---|---|
| **Sarah (Analyst)** | The human whose approval is requested; receives the notification and authenticates on her phone |
| **Orchestrator Agent** | Initiates the CIBA backchannel auth request to Keycloak on behalf of the Email Agent |
| **Email Agent** | Halted at the Gateway; waits for the CIBA token before `send_email` can proceed |
| **Gateway** | Detects risk score > 0.75; instructs Orchestrator to initiate CIBA; resumes the Email Agent only after a valid token is received |
| **Keycloak** | Authorization server — manages the CIBA flow, calls the ACP, issues the signed approval token |
| **ACP (FastAPI)** | Authentication Channel Provider — routes Keycloak's notification to Sarah's phone via SNS or Duo |
| **OPA** | Consulted by the Gateway after CIBA approval to confirm token scopes satisfy the send_email policy |

CIBA is not involved in Steps 1–7. Those steps are handled by OIDC (Sarah's login), SPIRE (agent identity), Macaroon attenuation (scope), OPA, and the LLM Judge.

### CIBA Call Flow — Step 8 in Full

```
Email Agent    Gateway     Orchestrator     Keycloak          ACP         Sarah's Phone
     │              │             │              │               │               │
     │ send_email() │             │              │               │               │
     ├────────────► │             │              │               │               │
     │              │             │              │               │               │
     │         Risk score = 0.82  │              │               │               │
     │         threshold = 0.75   │              │               │               │
     │         → CIBA required    │              │               │               │
     │              ├────────────►│              │               │               │
     │              │  initiate   │              │               │               │
     │     [HALTED] │  CIBA flow  │              │               │               │
     │              │             │ POST /ciba/auth               │               │
     │              │             │ login_hint=sarah@firm.com     │               │
     │              │             │ scope=approve:send_email      │               │
     │              │             │ binding_message="Approve:     │               │
     │              │             │  Email Agent will send        │               │
     │              │             │  Acme Q1 2026 (CONFIDENTIAL)  │               │
     │              │             │  to investment-team@firm.com" │               │
     │              │             ├─────────────────────────────► │               │
     │              │             │              │               │               │
     │              │             │ ◄── auth_req_id: ciba-req-9d4e1a2b ─────────┤
     │              │             │     expires_in: 300s         │               │
     │              │             │     interval: 5s             │               │
     │              │             │              │               │               │
     │              │             │              │ POST /notify  │               │
     │              │             │              │ (auth_req_id, │               │
     │              │             │              │  binding_msg) │               │
     │              │             │              ├──────────────►│               │
     │              │             │              │               │  SMS (SNS)    │
     │              │             │              │               ├──────────────►│
     │              │             │              │               │  OR Duo Push  │
     │              │             │              │               ├──────────────►│
     │              │             │              │               │               │
     │              │             │  [polling every 5s ...]      │   Sarah reads │
     │              │             │  POST /token                 │   binding msg │
     │              │             │  (auth_req_id)               │   taps Approve│
     │              │             ├─────────────────────────────►│ ◄────────────┤
     │              │             │              │               │  (Face ID ✓) │
     │              │             │              │               │               │
     │              │             │ ◄── JWT access_token ───────┤               │
     │              │             │     sub: sarah@firm.com      │               │
     │              │             │     scope: approve:send_email│               │
     │              │             │     auth_req_id: ciba-req-.. │               │
     │              │             │              │               │               │
     │              │  token      │              │               │               │
     │              │ ◄──────────┤              │               │               │
     │              │             │              │               │               │
     │              │  validate:  │              │               │               │
     │              │  sig ✓      │              │               │               │
     │              │  exp ✓      │              │               │               │
     │              │  scope ✓    │              │               │               │
     │              │  OPA ✓      │              │               │               │
     │              │             │              │               │               │
     │  ✓ resume    │             │              │               │               │
     │ ◄────────── │             │              │               │               │
     │              │             │              │               │               │
     │  send_email  │             │              │               │               │
     │  executed    │             │              │               │               │
```

### What the Binding Message Looks Like on Sarah's Phone

```
╔══════════════════════════════════════════════════════╗
║  Firm AI System — Approval Required                  ║
║                                                      ║
║  Email Agent will send:                              ║
║    "Competitive Analysis — Acme Corp Q1 2026         ║
║     (CONFIDENTIAL)"                                  ║
║  To: investment-team@firm.com                        ║
║  Intent: intent-8a3f2c1d (your research request)     ║
║                                                      ║
║         [  APPROVE  ]    [  DENY  ]                  ║
╚══════════════════════════════════════════════════════╝
```

Sarah approves the exact action described — not a vague "the agent wants to do something." If the binding message does not match what she asked for, she denies it.

### What the Gateway Does with the Token

Once the CIBA access token arrives, the Gateway does not blindly trust it. It runs four checks before resuming the Email Agent:

| Check | Detail |
|---|---|
| Signature | Verifies the JWT is signed by Keycloak's public key |
| Expiry | Rejects tokens where `exp` has passed (300s TTL) |
| Scope | Confirms `approve:send_email` is present in the token |
| OPA | Passes the token claims as input to the Rego policy — `sub = sarah@firm.com`, `role = analyst`, `approved_tool = send_email` |

The `auth_req_id` is attached to the OTel span as a trace attribute, linking the Keycloak approval event to the exact tool call in Jaeger.

### Risk Score → CIBA Trigger Table

| Step | Tool | Data classification | Risk Score | CIBA Triggered? | Gateway action |
|---|---|---|---|---|---|
| 3 | `web_search` | public | 0.20 | No | Allow |
| 5 | `query_internal_db` | **confidential** | **0.65** | No | Allow + mandatory OPA audit flag |
| 7 | `generate_report` | internal + public | 0.45 | No | Allow |
| **8** | **`send_email`** | **confidential (attachment)** | **0.82** | **Yes** | **Halt → CIBA → resume on approval** |

> **Why `query_internal_db` scores 0.65 and not lower:** Earlier versions of this system scored `query_internal_db` at 0.55 — treating it the same as a generic internal read. That was too low. In a financial firm, internal portfolio exposure data reveals proprietary trading positions and fund strategy. Even a read-only query against this data carries meaningful risk if the agent is compromised or manipulated. The score was raised to 0.65 to reflect the `confidential` data classification accurately. It stays below the 0.75 CIBA threshold because the data never leaves the system at this step — egress is what makes a `confidential` read CIBA-worthy, not the read itself.

### How Scores Compound Across Steps

The score at `send_email` (Step 8) is not calculated independently — it compounds the risk of the data it carries:

```
query_internal_db  →  data_classification: confidential  →  score: 0.65
                                │
                                │  data tagged and passed to Report Generation Agent
                                ▼
generate_report    →  synthesises confidential data into PDF  →  score: 0.45 (synthesis only)
                                │
                                │  doc-f7a3c219 tagged: data_classification: confidential
                                ▼
send_email         →  external communication + confidential attachment
                   →  score: 0.82  →  CIBA triggered
```

The `send_email` call is scored high (0.82) precisely because it is the **exfiltration point** — it takes data classified `confidential` and moves it outside the system boundary via email. Without the confidential attachment, the same `send_email` call to an internal address would score ~0.50. The compound scoring means the gateway tracks data sensitivity through the pipeline, not just the tool being called.

### Risk Scoring Model — Data Classification Tiers

The Gateway's composite risk score is driven by three factors: **data sensitivity** (what classification is the data?), **tool blast radius** (can this tool exfiltrate, modify, or delete?), and **anomaly signal** (is this agent behaving outside its normal pattern?). Data classification is the dominant factor for read-only operations; blast radius becomes dominant when data crosses a system boundary.

| Data classification | Base score contribution | CIBA triggered? | Compensating controls when CIBA not triggered |
|---|---|---|---|
| `internal` | 0.20–0.35 | No | Macaroon scope, OPA allow |
| `confidential` | 0.60–0.70 | No (read-only, stays internal) | OPA mandatory audit flag, full OTel trace, Macaroon restricts result to caveat holders |
| `confidential` + external egress | 0.80+ | **Yes** | CIBA approval required — this is Step 8 |
| `restricted` | 0.80+ | **Yes** | CIBA approval required even for read-only queries |

**Design principle:** CIBA is reserved for moments where human approval is *the only meaningful control* — when data leaves the system, when `restricted`-class data is touched at all, or when the action is irreversible. For `confidential` reads that stay internal, the combination of Macaroon scoping, OPA audit flagging, and full distributed tracing provides sufficient oversight without requiring the human to approve every query. Triggering CIBA for every confidential read would cause approval fatigue, training analysts to approve without reading — which is worse than not having CIBA at all.

---

## Implementation in This Project

| Component | Detail |
|---|---|
| **IDP** | Keycloak 21 (self-hosted on EKS) — CIBA supported natively since v18 |
| **ACP** | Custom FastAPI service (`acp.firm.internal`) — receives Keycloak's notification POST, routes to SNS or Duo |
| **Primary channel** | AWS SNS → SMS — no app required; phone number stored in Keycloak user attribute |
| **Rich channel** | Duo Mobile via Duo Auth API + Keycloak Duo SPI plugin — Approve/Deny push UI |
| **Polling mode** | Agent polls `/protocol/openid-connect/token` with `auth_req_id` at `interval` seconds |
| **Token use** | CIBA access token attached to approved action; validated by Envoy + OPA at the gateway |
| **Audit** | `auth_req_id` propagated as OTel span attribute; links Keycloak logs ↔ agent trace ↔ tool call |
| **TTL** | Configurable per-realm; default 300 seconds — agent raises `ApprovalTimeout` and halts on expiry |

### Why Standard Authenticator Apps (Google Authenticator, Authy) Do Not Work Here

TOTP apps generate time-based codes on demand — they have no ability to receive an inbound notification or display a `binding_message`. They cannot participate in an asynchronous, server-initiated approval flow. CIBA requires a channel that Keycloak can push to; Duo Mobile provides this via the Duo Auth API. SMS via SNS is the fallback requiring no app at all.

---

## Threat Model Considerations

| Threat | CIBA Mitigation |
|---|---|
| Compromised agent auto-approves its own actions | Approval channel is the user's phone, physically separate from the agent runtime |
| Approval for one action re-used for another | `auth_req_id` is single-use; token scopes are tied to the specific request |
| Agent requests broad scope under a narrow description | `binding_message` is shown verbatim; user approves the exact description |
| Replay of an old CIBA token | Token carries `iat` + `exp`; gateway rejects expired tokens; `auth_req_id` is one-time |
| CIBA approval notification intercepted | SMS is low-assurance; Duo Mobile push uses TLS + Duo's signed push channel |
| Denial of service via approval fatigue | Rate limiting on CIBA initiation per agent; risk threshold prevents trivial triggers |

---

## References

- [OpenID CIBA Core Specification 1.0](https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html)
- [Keycloak CIBA documentation](https://www.keycloak.org/docs/latest/server_admin/#_client_initiated_backchannel_authentication_grant)
- [Duo Auth API — Push Notifications](https://duo.com/docs/authapi)
- [Keycloak Duo SPI Plugin](https://github.com/mths0x5f/keycloak-duo-spi)
- [AWS SNS — Simple Notification Service](https://docs.aws.amazon.com/sns/latest/dg/welcome.html)
- [FAPI 2.0 Security Profile (uses CIBA for financial-grade APIs)](https://openid.net/specs/fapi-2_0-security-profile.html)
- [Descope — CIBA Explained](https://www.descope.com/learn/post/ciba)
