# Agentic AI Security — Requirements

## 1. Identity and Authentication

### 1.1 Human and Non-Human Identities
- Every agent and sub-agent must be assigned a **unique, non-shared identity** with scoped access controls.
- Non-human identities (agents, services) must be treated as first-class principals — not trusted implicitly.
- Identity provisioning for agents should leverage workload identity frameworks such as **SPIRE** (SPIFFE Runtime Environment).

### 1.2 Authentication Protocols
- Use **CIBA (Client-Initiated Backchannel Authentication)** — an OAuth 2.0 extension — to support asynchronous, decoupled authentication flows appropriate for agentic workloads.
- Integrate with a trusted **Identity Provider (IDP)** for federated authentication.

### 1.3 Delegation
- When an agent delegates work to a sub-agent, the sub-agent must **not inherit the caller's identity or privileges**.
- Each delegation must result in a freshly scoped credential, with only the permissions required for the delegated task.

---

## 2. Authorization and Least Privilege

### 2.1 Principle of Least Privilege
- Every agent must be granted only the permissions necessary for its specific task — no standing broad permissions.
- Privileges must be scoped to the **intent** of the operation, not a general role.

### 2.2 Just-in-Time (JIT) Trust
- Replace standing policies with **just-in-time trust grants** that are issued at runtime based on verified intent.
- Trust must be earned per-action, not inherited from a prior authorization.

### 2.3 Self-Attenuating Scope
- Implement **scope trimming**: as work is delegated down the agent hierarchy, permissions must narrow, never broaden.
- No agent in a chain may possess more authority than the agent that called it.

### 2.4 Intent-Driven Access (UADP)
- Adopt a **UADP (User/Agent/Device/Policy) intent-to-policy** structure for authorization decisions.
- Authorization must be tied to the declared and verified intent of an action, not just its syntactic form.

---

## 3. Tool Security and Registry

### 3.1 Approved Tool Enforcement
- Agents must only be permitted to call **explicitly approved tools**. Unrestricted tool access is not acceptable.
- Tool approval must be intent-driven: a tool invocation must match the agent's declared task intent.

### 3.2 Tool Integrity Verification
- Maintain a **tool registry with cryptographic hashes** for each registered tool.
- Before any tool is invoked, verify its identity and integrity against the registry to prevent substitution with a malicious implementation of the same name.

### 3.3 LLM-as-Judge for Tool Calls
- Deploy an **internal LLM-as-a-judge** component to semantically evaluate whether a tool call matches the agent's current intent.
- If the tool call does not match the intent, it must be blocked — this provides a dynamic, semantic policy layer that complements (or may reduce reliance on) hardcoded policy engines.

---

## 4. Prompt Injection and Jailbreak Prevention

### 4.1 Direct Prompt Injection
- Implement guardrails to detect and block **jailbreak attempts** and **direct prompt injection** against agent system prompts and instructions.

### 4.2 Indirect Prompt Injection
- Defend against **indirect prompt injection** from external data sources such as web search results, retrieved documents, and open tool outputs.
- All external content returned to an agent must be treated as untrusted and inspected before influencing agent behavior.

### 4.3 Semantic Inspection
- Perform **semantic inspection** of inputs and outputs — not purely syntactic pattern matching — to catch obfuscated or novel injection techniques.
- Reference taxonomy: [arc_pi_taxonomy](https://github.com/Arcanum-Sec/arc_pi_taxonomy) for known prompt injection patterns.

---

## 5. Zero Trust Architecture

### 5.1 Verify-Then-Trust
- Apply a **zero trust** model throughout: no implicit trust based on network location, identity label, or prior session.
- Every request must be verified at the time it is made.

### 5.2 Dynamic Policy Engine
- Policies must be **dynamically evaluated** at runtime, not statically applied.
- The system should support **dynamic policy writing** in response to emerging context or risk signals.

### 5.3 Policy Preferences and Guardrails
- Define **policy preferences** that express security posture (e.g., sensitivity of data, blast radius of tools) and use these to constrain agent behavior automatically.
- Guardrails must be enforced at every layer of the agent stack.

---

## 6. Agent Gateway / Firewall

### 6.1 Agentic AI Gateway
- Deploy an **agentic AI firewall or gateway** that sits between agents and the resources/tools they interact with.
- The gateway must enforce: tool access control, rate limiting, intent validation, and audit logging.

### 6.2 Throttling and Human-in-the-Loop
- Implement **request throttling** to prevent runaway agents from causing outsized harm.
- For high-stakes or anomalous actions, trigger a **human-in-the-loop** review before execution proceeds.

### 6.3 RBAC
- Apply **Role-Based Access Control (RBAC)** at the gateway layer to enforce which agents can access which tools and data.

---

## 7. Audit, Observability, and Accountability

### 7.1 End-to-End Audit Trail
- **Audit everything** across the full agent lifecycle — from initial user intent through every sub-agent call and tool invocation to final output.
- Audit records must be tamper-evident and attributable to specific agent identities.

### 7.2 Federated Workload Visibility
- Federate observability data across all agents and services to provide a **unified view of system behavior**.
- Support cross-agent tracing to understand how a top-level intent propagates through the agent graph.

### 7.3 Action-to-Intent Binding
- Every audited action must be traceable back to the **originating user intent** that authorized it.

---

## 8. Posture and Threat Management

### 8.1 Posture Checks
- Continuously assess the security posture of the agentic system — including agent configurations, policy coverage, and tool registry integrity.
- Use **red teaming** exercises to proactively identify weaknesses in agent behavior and guardrails.

### 8.2 Runtime Protection
- Provide **runtime threat detection** to identify anomalous agent behavior, unexpected tool calls, or signs of prompt injection in flight.
- Align with **CNAPP 2.0** capabilities extended for agentic workloads (posture management + runtime protection for AI agents).

---

## 9. Key Principles Summary

| Principle | Description |
|---|---|
| Least Privilege | Agents get only what they need for the current task |
| Zero Trust | Every action is verified; no standing trust |
| Just-in-Time Trust | Trust granted per-action, not per-session |
| Intent-Driven Authorization | Permissions tied to verified intent, not just identity |
| Self-Attenuating Scope | Delegated agents cannot exceed caller's permissions |
| Semantic Inspection | Policy enforcement understands meaning, not just syntax |
| Non-Human Identity | Agents are first-class principals with unique credentials |
| Audit Everything | Full lineage from user intent to every downstream action |

---

## 10. References

- [CIBA — OAuth 2.0 Client-Initiated Backchannel Authentication](https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html)
- [SPIRE — SPIFFE Runtime Environment](https://spiffe.io/docs/latest/spire-about/)
- [arc_pi_taxonomy — Prompt Injection Taxonomy](https://github.com/Arcanum-Sec/arc_pi_taxonomy)
- [Reference Video 1](https://www.youtube.com/watch?v=YQdm32PZWaM)
- [Reference Video 2](https://www.youtube.com/watch?v=j51uMah-3js)
