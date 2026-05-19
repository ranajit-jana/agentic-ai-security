# Observability & Correlation — Design Guide

## Data Sources in Grafana

```
┌─────────────────────────────────────────────────────────┐
│  Grafana                                                 │
│                                                          │
│  Datasource 1: Loki        ← all structured app logs    │
│  Datasource 2: OpenSearch  ← SIEM / correlation (Ph3)   │
│  Datasource 3: Prometheus  ← metrics / rates            │
└─────────────────────────────────────────────────────────┘
```

---

## What Flows Where

| Source | Ships to | How |
|---|---|---|
| Security Gateway | Loki | OTel Collector |
| Agents (all 4) | Loki | OTel Collector |
| Keycloak / CIBA ACP | Loki | OTel Collector |
| OPA decisions | Loki | OTel Collector |
| Hash Verifier | Loki | OTel Collector |
| KubeArmor runtime blocks | Loki + OpenSearch | Fluent Bit (Phase 3) |
| GuardDuty findings | OpenSearch | CloudWatch → OTel → OpenSearch |
| Gap analysis results | OpenSearch | CronJob direct write |

---

## Grafana Dashboards

| Dashboard | Datasource | What it shows |
|---|---|---|
| **Security Gateway** | Loki | Every tool call decision — allow/deny, OPA result, Cedar result, LLM judge score, HITL triggers |
| **Agent Activity** | Loki | Per-agent log stream — orchestrator, web-search, internal-data, email, report |
| **CIBA / Approvals** | Loki | Approval requests, Duo push events, approval outcomes, timeout rates |
| **KubeArmor Runtime** | Loki | Process blocks, network blocks, file access blocks — per pod/namespace |
| **Security Posture** | Loki + OpenSearch | Policy coverage %, injection attempts, Biscuit violations, GuardDuty findings, KubeArmor block count |
| **Threat Correlations** | OpenSearch | Fired correlation rules — injection+tool call, runtime block+GuardDuty |
| **Logs / App** | Loki | Raw log explorer for any service |

---

## Loki vs OpenSearch — The Key Split

- **Loki** answers: *"What did this agent do at 14:32?"* — per-event, per-service log lookup
- **OpenSearch** answers: *"Did an injection attempt and a tool call happen together from the same agent within 60 seconds?"* — cross-event pattern matching with time windows

Loki cannot join events across sources. OpenSearch Security Analytics can.

---

## KubeArmor Log Pipeline (Phase 3)

Without Fluent Bit, KubeArmor blocks are invisible to Grafana — they exist only in `kubectl logs` on the relay pod.

```
KubeArmor Relay (gRPC :32767)
        │
        ▼
  Fluent Bit DaemonSet
        ├──► Loki          (KubeArmor Runtime dashboard + Posture dashboard)
        └──► OpenSearch    (available for cross-source correlation rules)
```

---

## Correlation Options — Full Comparison

### The 3 correlation rules in Phase 3

| Rule | Type | Complexity |
|---|---|---|
| Injection → tool call within 60s, same agent_id | Cross-event, same source, time window | Medium |
| KubeArmor block + GuardDuty on same node within 5 min | Cross-source, different systems | Hard |
| Biscuit violation count threshold | Rate-based | Easy |

Only rule 2 genuinely requires a cross-source correlation engine.

---

### Option 1: Grafana Alerting + LogQL (already deployed)

```
Loki ──► Grafana Alerting rules
              └── LogQL: find agent_id with scan_result=unsafe
                  AND event_type=tool_call within 60s window
```

- Works for: same-source correlations (both events in Loki)
- Fails for: cross-source (KubeArmor + GuardDuty are different systems)
- Cost: $0 extra
- Limitation: LogQL `join` is very limited

---

### Option 2: Grafana + Tempo (distributed tracing)

```
Agents emit traces → OTel → Tempo
Grafana links trace ID across injection event + tool call
```

- Best for: correlating events within a single request flow (same trace ID)
- Not a SIEM — no time-window pattern matching across unrelated events
- Cost: ~$10/month (small Tempo instance)
- Better fit if concern is "what happened in this specific request chain"

---

### Option 3: Vector (Rust log router) — Recommended lightweight option

```
KubeArmor relay ──► Vector
Loki HTTP tail  ──► Vector  ──► Fires webhook/SNS on pattern match
GuardDuty       ──►
```

- Can do stateful event correlation via `reduce` transform
- Correlation logic written in VRL (Vector Remap Language) — simple config
- No UI — alerts go to SNS/Slack/webhook, viewed in Grafana via Loki
- Cost: ~$0 (single lightweight pod, ~50MB RAM)
- Stateless — fits the nightly destroy/rebuild workflow perfectly

---

## Vector — Deep Dive

### What is Vector?

Vector is an open-source, high-performance observability data pipeline written in Rust.
Built by Datadog (acquired 2021), but fully open-source under the MPL-2.0 licence.
Project: https://github.com/vectordotdev/vector

It sits between your data sources and your backends. Instead of running separate agents
for logs, metrics, and traces, Vector handles all three in a single binary.

```
Sources (inputs)          Transforms (processing)       Sinks (outputs)
─────────────────         ───────────────────────       ───────────────
Kafka                     filter                        Loki
Kubernetes logs     ──►   remap (VRL)            ──►   OpenSearch
HTTP / webhook            reduce (correlation)          S3
Syslog                    route (fan-out)               SNS / webhook
File tail                 throttle                      Prometheus
gRPC (KubeArmor)          deduplicate                   Kafka
...60+ sources            ...30+ transforms             ...50+ sinks
```

Everything is configured in a single TOML or YAML file — no code, no JVM, no Python runtime.

---

### Architecture — How Vector works internally

Vector processes events as a **directed acyclic graph (DAG)**. Each node in the graph
is either a source, transform, or sink. Events flow through the graph in order.

```
[source: kubearmor_relay]
        │
        ▼
[transform: parse_json]       ← parse raw gRPC message into structured fields
        │
        ▼
[transform: enrich_node]      ← add node name, namespace, timestamp
        │
        ├──────────────────────────────────────────────┐
        ▼                                              ▼
[transform: filter_blocks]                   [transform: all_events]
  only Action=Block                            everything
        │                                              │
        ▼                                              ▼
[transform: correlate]                        [sink: loki]
  reduce: group by node_name                   ship all events to Loki
  window: 300s
  condition: has kubearmor_block
             AND has guardduty_finding
        │
        ▼
[sink: sns_alert]
  fire SNS when correlation matches
```

This graph is statically compiled at startup — no dynamic routing overhead.

---

### VRL — Vector Remap Language

VRL is Vector's built-in scripting language for transforming events. It is:
- **Compiled at startup** — not interpreted at runtime, so it is fast
- **Purely functional** — no loops, no side effects, no external calls
- **Type-safe** — errors are caught at compile time, not when events flow through

A simple example — parsing a KubeArmor event and enriching it:

```coffee
# parse the JSON body
. = parse_json!(.message)

# rename fields to a common schema
.event_source = "kubearmor"
.pod          = .PodName
.namespace    = .NamespaceName
.action       = .Action           # "Block" or "Audit"
.syscall      = .Resource
.timestamp    = now()

# drop fields we don't need
del(.ClusterName)
del(.UID)
```

A correlation example — detecting injection followed by tool call within 60s:

```coffee
# This runs inside a [transform: reduce] block
# Vector accumulates events by group_by key (agent_id)
# and fires when the condition is true within the time window

.has_injection = exists(.scan_result) && .scan_result == "unsafe"
.has_tool_call = exists(.event_type) && .event_type == "tool_call"

# Vector fires this event downstream only when BOTH are true
# within the 60s window for the same agent_id
.correlation_fired = .has_injection && .has_tool_call
```

---

### The `reduce` transform — how correlation actually works

`reduce` is the key transform for correlation. It:
1. Groups incoming events by one or more fields (e.g. `agent_id`)
2. Accumulates events within a time window
3. Merges them into a single output event
4. Fires downstream when an `ends_when` condition is met OR the window expires

```toml
[transforms.correlate_injection_toolcall]
type      = "reduce"
inputs    = ["gateway_events"]
group_by  = ["agent_id"]

# accumulate for up to 60 seconds
expire_after_ms = 60000

# merge strategy: keep first value for agent_id, boolean OR for flags
merge_strategies.agent_id      = "retain"
merge_strategies.has_injection = "logical_or"
merge_strategies.has_tool_call = "logical_or"

# fire when both flags are true within the window
ends_when = '.has_injection == true && .has_tool_call == true'
```

When `ends_when` fires, Vector emits one merged event to the downstream sink
(SNS, webhook, Loki alert index). If the window expires without both being true,
the accumulated event is discarded.

---

### Vector vs Fluent Bit vs Logstash

| | Vector | Fluent Bit | Logstash |
|---|---|---|---|
| Language | Rust | C | JRuby/JVM |
| RAM footprint | ~50 MB | ~20 MB | ~500 MB+ |
| Stateful correlation | Yes (`reduce`) | No | Limited |
| Config language | TOML/YAML + VRL | INI-like | Ruby DSL |
| Metrics support | Yes (native) | Plugin only | Plugin only |
| Throughput | Very high | High | Medium |
| Best for | Full pipeline + correlation | Lightweight log forwarding | Complex ETL |

Fluent Bit is better when you just need to forward logs from A to B with minimal overhead.
Vector is better when you need to transform, correlate, or route across multiple destinations.
Logstash is largely superseded by both for new deployments.

---

### How Vector fits in this project

```
Phase 3 deployment:

  [KubeArmor relay]  ──gRPC──►  Vector pod (in observability namespace)
  [Loki HTTP tail]   ──HTTP──►       │
  [GuardDuty/CW]     ──HTTP──►       │
                                     ├──► Loki          (all events, for dashboards)
                                     ├──► SNS alert     (when correlation fires)
                                     └──► Loki alert    (correlation match as a log event)
```

Vector runs as a single Deployment (not DaemonSet — it pulls, not tails).
It is completely stateless between restarts — no PVC needed.
On cluster rebuild it starts up in seconds and immediately begins correlating.

Config lives in a ConfigMap mounted into the pod — updated via helmfile on every deploy.

---

### Vector Helm chart

```yaml
# helmfile/phase3/values/vector.yaml
role: Stateless-Aggregator    # single pod, pulls from sources

customConfig:
  sources:
    kubearmor_relay:
      type: http_client
      endpoint: http://kubearmor-relay.kubearmor-system.svc.cluster.local:32767/events
      scrape_interval_secs: 5

    loki_tail:
      type: http_client
      endpoint: http://loki.observability.svc.cluster.local:3100/loki/api/v1/tail
      query: '{job="security-gateway"}'
      scrape_interval_secs: 2

  transforms:
    correlate_injection:
      type: reduce
      inputs: ["loki_tail"]
      group_by: ["agent_id"]
      expire_after_ms: 60000
      merge_strategies.has_injection: logical_or
      merge_strategies.has_tool_call: logical_or
      ends_when: .has_injection == true && .has_tool_call == true

  sinks:
    loki_out:
      type: loki
      inputs: ["kubearmor_relay", "loki_tail"]
      endpoint: http://loki.observability.svc.cluster.local:3100
      labels:
        source: vector

    sns_alert:
      type: aws_sns
      inputs: ["correlate_injection"]
      topic_arn: "${SNS_ALERT_TOPIC_ARN}"
      region: ap-south-1

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

---

### Learning resources

- Official docs: https://vector.dev/docs
- VRL playground (test transforms in browser): https://playground.vector.dev
- VRL reference (all functions): https://vector.dev/docs/reference/vrl
- `reduce` transform reference: https://vector.dev/docs/reference/configuration/transforms/reduce
- Helm chart: https://github.com/vectordotdev/helm-charts

---

### Option 4: OpenSearch Security Analytics (current Phase 3 plan)

- Purpose-built SIEM with UI, pre-built Security Analytics correlation rules
- Best cross-source correlation with time windows
- 30Gi EBS per node (3 nodes) — sized for one day's data, ISM policy auto-deletes after 1d
- Cost: ~$82/month at 10h/day
- Teardown: destroyed nightly with the cluster, rules reloaded automatically on rebuild
- Right choice for enterprise/compliance requirements (SOC2, ISO27001)

---

### Option 5: AWS EventBridge + CloudWatch

```
KubeArmor → Fluent Bit → CloudWatch Logs
GuardDuty → CloudWatch Events
EventBridge rule: pattern match across both → SNS alert
```

- Fully serverless — no Kubernetes workload at all
- EventBridge does cross-source pattern matching natively
- Cost: near $0 (pay per event, pennies at this scale)
- Limitation: no UI — alerts only, view in CloudWatch or via Grafana CloudWatch datasource

---

### Comparison Table

| Option | Cross-source | UI | Extra infra | Cost/month |
|---|---|---|---|---|
| Grafana Alerting | No | Grafana | None | $0 |
| Grafana + Tempo | Partial (traces only) | Grafana | Tempo pod | ~$10 |
| Vector | Yes | None (SNS/Slack) | 1 pod | ~$0 |
| OpenSearch | Yes | OpenSearch Dashboards + Grafana | 3 nodes | ~$82 |
| AWS EventBridge | Yes | CloudWatch | None | ~$0 |

---

## Recommendation for This Project

**Vector + Grafana Alerting** — covers all 3 rules, zero extra cost, stateless (destroy/rebuild safe).

| Rule | Handled by |
|---|---|
| Injection → tool call within 60s | Grafana Alerting on Loki (LogQL) |
| Biscuit violation threshold | Grafana Alerting on Loki (LogQL) |
| KubeArmor + GuardDuty cross-source | Vector reduce transform → SNS alert |

Keep OpenSearch only if compliance requirements mandate a certified SIEM or if scaling to dozens of agents generating thousands of events per second.

---

## OpenSearch Cost Breakdown (if kept)

| Scenario | EBS (3×30Gi) | Nodes (10h/day) | Total/month |
|---|---|---|---|
| Running 24/7 | ~$9 | ~$175 | ~$184 |
| Nightly destroy (10h/day) | ~$9 | ~$73 | ~$82 |

EBS volumes are destroyed nightly with the cluster — no persistent cost between rebuilds.
ISM policy auto-deletes indices older than 1 day so 30Gi never fills up.
