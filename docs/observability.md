# Observability & Correlation — Design Guide

## Data Sources in Grafana

```
┌─────────────────────────────────────────────────────────┐
│  Grafana (current — Phase 3 final)                      │
│                                                         │
│  Datasource 1: Loki        ← all structured app logs    │
│  Datasource 2: ClickHouse  ← correlation + analytics    │
│  Datasource 3: Prometheus  ← metrics / rates            │
│                                                         │
│  OpenSearch was here — removed. See Decision Record.    │
└─────────────────────────────────────────────────────────┘
```

---

## What Flows Where

| Source | Ships to | How |
|---|---|---|
| Security Gateway | Loki + Kafka | OTel Collector |
| Agents (all 4) | Loki + Kafka | OTel Collector |
| Keycloak / CIBA ACP | Loki | OTel Collector |
| OPA decisions | Loki + Kafka | OTel Collector |
| Hash Verifier | Loki | OTel Collector |
| KubeArmor runtime blocks | Loki + Kafka | Fluent Bit → Loki / Kafka topic |
| GuardDuty findings | Kafka | CloudWatch → OTel → Kafka topic |
| Flink CEP hits | ClickHouse + SNS | Flink sink |
| Gap analysis results | ClickHouse | CronJob direct write |

---

## Grafana Dashboards

| Dashboard | Datasource | What it shows |
|---|---|---|
| **Security Gateway** | Loki | Every tool call decision — allow/deny, OPA result, Cedar result, LLM judge score, HITL triggers |
| **Agent Activity** | Loki | Per-agent log stream — orchestrator, web-search, internal-data, email, report |
| **CIBA / Approvals** | Loki | Approval requests, Duo push events, approval outcomes, timeout rates |
| **KubeArmor Runtime** | Loki | Process blocks, network blocks, file access blocks — per pod/namespace |
| **Security Posture** | ClickHouse + Prometheus | Policy coverage %, injection attempts, Biscuit violations, GuardDuty findings, KubeArmor block count |
| **Threat Correlations** | ClickHouse | Flink CEP hits — injection→toolcall, probe→inject→exfil, KubeArmor+GuardDuty join |
| **Logs / App** | Loki | Raw log explorer for any service |

---

## OpenSearch — Decision Record

OpenSearch was originally planned as the SIEM and correlation engine for Phase 3.
It was **removed** and replaced by Apache Flink + ClickHouse.

### Why it was removed

| Reason | Detail |
|---|---|
| Correlation replaced | Flink CEP handles all correlation rules better — event-time accuracy, ordered patterns (A→B→C), stateful interval joins. None of these work in OpenSearch Security Analytics. |
| Analytics replaced | ClickHouse runs the same aggregation queries 50x faster (column-oriented vs document-oriented storage). |
| Cost | OpenSearch needed 3 dedicated EC2 nodes (~$73/month at 10h/day). Flink + ClickHouse fits on the existing system nodegroup — EBS only (~$9/month). |
| UI replaced | Grafana + ClickHouse datasource covers everything OpenSearch Dashboards provided. |
| Retention | ClickHouse TTL per table replaces OpenSearch ISM policy — simpler, no extra config. |

### When you WOULD use OpenSearch instead

| Scenario | Why OpenSearch |
|---|---|
| **Compliance audit (SOC2 / ISO27001)** | Auditors may require a named certified SIEM product. OpenSearch (and its upstream Elasticsearch) appear on approved SIEM lists. Grafana + ClickHouse does not. |
| **Pre-built Sigma detection rules** | OpenSearch Security Analytics ships with 2,000+ community Sigma rules out of the box. With Flink you write every CEP pattern yourself. |
| **Dedicated security team prefers SIEM UI** | OpenSearch Dashboards has investigation workflows (timeline, drilldown, alert management) designed for SOC analysts — not general-purpose like Grafana. |
| **Existing OpenSearch/Elasticsearch investment** | If the organisation already runs an OpenSearch cluster, it costs nothing extra to add this project's events as another index. |

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

## Apache Flink + ClickHouse — The Enterprise-Grade Choice

### What is Apache Flink?

Apache Flink is a distributed stream processing engine designed for stateful computations
over unbounded (streaming) and bounded (batch) data. It is the top choice in industry for
true real-time event correlation, used at scale by Alibaba, Netflix, Uber, and Lyft.

- Written in Java/Scala, Python API available (PyFlink)
- Processes millions of events per second on modest hardware
- Exactly-once processing guarantees — no duplicate alerts, no missed events
- Event-time processing — uses the timestamp embedded in the event, not when it arrived
  (critical for out-of-order events from distributed systems like KubeArmor + GuardDuty)
- Native Kubernetes operator for deployment
- Project: https://flink.apache.org

---

### Why Flink is fundamentally different from Vector/OpenSearch

Vector `reduce` and OpenSearch correlation rules work on **processing time** — they react
to when events arrive at the pipeline. If a KubeArmor block arrives 10 seconds late
(network delay, pod restart), the correlation window may have already expired and the
rule misses it.

Flink uses **event time + watermarks**:

```
Event timeline (what actually happened):
  T=0s   KubeArmor block fires
  T=3s   GuardDuty finding fires
  T=15s  KubeArmor event arrives at Flink (12s late due to relay lag)
  T=16s  GuardDuty event arrives at Flink (13s late)

Vector/OpenSearch: sees a 1s gap between arrivals → correlation window = fine
  BUT if KubeArmor arrived at T=65s → Vector would MISS the 60s window

Flink with watermarks: uses T=0s and T=3s (from the event itself) → always correct
```

Watermarks are Flink's mechanism for declaring "I have now seen all events up to time T".
The engine holds state open until the watermark advances past the window boundary.

---

### Complex Event Processing (CEP) in Flink

FlinkCEP is a library built on top of Flink's streaming API specifically for detecting
patterns in event sequences. It is the most powerful open-source CEP engine available.

**What CEP can detect that Vector/OpenSearch cannot:**

| Pattern type | Example | Vector | OpenSearch | Flink CEP |
|---|---|---|---|---|
| A then B within time T | injection → tool call in 60s | Yes (basic) | Yes | Yes |
| A then NOT B within T | login attempt with no MFA within 30s | No | Limited | Yes |
| A then B then C in order | probe → inject → exfiltrate sequence | No | No | Yes |
| A repeated N times in T | 5 OPA denials in 10s from same agent | Partial | Partial | Yes |
| A followed eventually by B | recon event → lateral movement (any time) | No | No | Yes |
| Absence detection | agent active but no audit logs for 5min | No | No | Yes |

**FlinkCEP pattern definition (Java API):**

```java
// Pattern: probe (OPA deny) followed by injection attempt
// followed by successful tool call — all within 2 minutes
Pattern<SecurityEvent, ?> attackPattern = Pattern
    .<SecurityEvent>begin("probe")
        .where(event -> event.getType().equals("opa_deny"))
    .next("inject")
        .where(event -> event.getScanResult().equals("unsafe"))
        .within(Time.seconds(30))
    .next("toolcall")
        .where(event -> event.getEventType().equals("tool_call")
                     && event.getDecision().equals("allow"))
        .within(Time.minutes(2));

// Apply pattern to stream
PatternStream<SecurityEvent> patternStream =
    CEP.pattern(securityStream.keyBy(SecurityEvent::getAgentId), attackPattern);

// Fire alert when full pattern matches
patternStream.select(matchedEvents -> {
    SecurityAlert alert = new SecurityAlert();
    alert.setSeverity("CRITICAL");
    alert.setPattern("probe_inject_exfiltrate");
    alert.setAgentId(matchedEvents.get("probe").get(0).getAgentId());
    return alert;
}).addSink(snsSink);
```

**PyFlink equivalent (if you prefer Python):**

```python
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer
from pyflink.cep import Pattern, CEP
from pyflink.common.time import Time

attack_pattern = (
    Pattern.begin("probe")
        .where(lambda e: e["type"] == "opa_deny")
    .next("inject")
        .where(lambda e: e["scan_result"] == "unsafe")
        .within(Time.seconds(30))
    .next("toolcall")
        .where(lambda e: e["event_type"] == "tool_call")
        .within(Time.minutes(2))
)
```

---

### Stateful Joins across streams

Flink can join two completely independent event streams with time constraints.
This is what makes the KubeArmor + GuardDuty correlation truly reliable.

**Interval Join** — the most useful for security correlation:

```java
// Join KubeArmor blocks with GuardDuty findings
// where both events occurred within 5 minutes on the same node

kubeArmorStream
    .keyBy(event -> event.getNodeName())          // group by node
    .intervalJoin(
        guardDutyStream.keyBy(event -> event.getResourceId())
    )
    .between(Time.minutes(-5), Time.minutes(5))   // ±5 min window
    .process((kubeEvent, gdEvent, ctx, out) -> {
        out.collect(new CorrelationAlert(
            "runtime_anomaly_cluster",
            kubeEvent.getNodeName(),
            kubeEvent.getTimestamp(),
            gdEvent.getSeverity()
        ));
    });
```

**What makes this powerful:** both streams are independently keyed and joined.
Even if GuardDuty fires 4 minutes after KubeArmor, Flink holds both in state
and correctly fires the alert.

---

### ClickHouse — The Analytics Backend

ClickHouse is a column-oriented OLAP database built for analytical queries on large
volumes of event data. It is orders of magnitude faster than OpenSearch or PostgreSQL
for aggregation queries.

**Why ClickHouse pairs perfectly with Flink:**

```
Flink (stream processor)          ClickHouse (analytics store)
─────────────────────────         ──────────────────────────────
Real-time CEP + correlation  ──►  Store enriched/correlated events
Stateful joins               ──►  Query: "all attacks in last 7 days"
Watermark-aware windows      ──►  Dashboard: trends, rates, patterns
Alert generation             ──►  Audit trail for compliance
```

**Query speed comparison for "count OPA denials by agent, last 1 hour":**

| Database | Query time (1M events) |
|---|---|
| OpenSearch | ~800ms |
| PostgreSQL | ~1200ms |
| Loki (LogQL) | ~2000ms |
| **ClickHouse** | **~12ms** |

ClickHouse stores data in columns, so a query that only touches `agent_id` and
`decision` columns never reads the other 20 fields. OpenSearch reads full documents.

**ClickHouse table design for this project:**

```sql
CREATE TABLE security_events (
    timestamp        DateTime64(3),
    event_source     LowCardinality(String),   -- 'kubearmor', 'gateway', 'opa'
    agent_id         String,
    node_name        LowCardinality(String),
    event_type       LowCardinality(String),
    decision         LowCardinality(String),   -- 'allow', 'deny', 'block'
    scan_result      LowCardinality(String),   -- 'safe', 'unsafe'
    severity         LowCardinality(String),
    raw              String                    -- full JSON
)
ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(timestamp)
ORDER BY (timestamp, event_source, agent_id)
TTL timestamp + INTERVAL 1 DAY DELETE;    -- auto-delete after 1 day (like OpenSearch ISM)
```

`LowCardinality` is a ClickHouse optimization — for fields with few distinct values
(like `decision = allow/deny`) it uses dictionary encoding, saving 10x storage and
making GROUP BY queries 5x faster.

**Grafana → ClickHouse:**
Grafana has an official ClickHouse datasource plugin. You write SQL directly:

```sql
-- OPA deny rate by agent over last 1 hour
SELECT
    toStartOfMinute(timestamp) AS time,
    agent_id,
    count() AS denials
FROM security_events
WHERE timestamp >= now() - INTERVAL 1 HOUR
  AND decision = 'deny'
GROUP BY time, agent_id
ORDER BY time
```

This query on 10M events takes ~50ms in ClickHouse. The same query in OpenSearch
takes ~3-5 seconds.

---

### Full architecture: Flink + ClickHouse + Grafana

```
Event Sources                 Flink (stream processing)         Sinks
─────────────                 ──────────────────────────        ─────
KubeArmor relay  ──Kafka──►   Source: Kafka consumer            ClickHouse ──► Grafana
Security Gateway ──Kafka──►   Transform: enrich + normalize          │           dashboards
OPA decisions    ──Kafka──►   CEP: pattern detection            SNS / Slack ──► alerts
GuardDuty        ──Kafka──►   Join: interval joins across            │
Keycloak events  ──Kafka──►         streams                     Loki ──► existing
                              Sink: ClickHouse + SNS + Loki          Grafana panels
```

Kafka sits in the middle as a durable buffer — events are not lost if Flink
restarts. Flink reads from Kafka offsets and resumes exactly where it left off.

---

### Flink on Kubernetes — the Flink Operator

```yaml
# helmfile/phase3/values/flink.yaml — example
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata:
  name: security-correlator
  namespace: observability
spec:
  image: flink:1.18-java11
  flinkVersion: v1_18
  jobManager:
    resource:
      memory: 1024m
      cpu: 0.5
  taskManager:
    replicas: 2
    resource:
      memory: 2048m
      cpu: 1.0
  job:
    jarURI: local:///opt/flink/usrlib/security-correlator.jar
    parallelism: 2
    upgradeMode: stateless
```

JobManager: coordinates the job (1 replica, lightweight).
TaskManager: does the actual processing (2 replicas, each handles half the partitions).
Total RAM: ~5GB — fits on the existing `system` nodegroup.

---

### Flink vs Vector vs OpenSearch for this project

| Capability | Vector | OpenSearch | Flink + ClickHouse |
|---|---|---|---|
| Real-time correlation | Basic | Yes | Yes — event-time accurate |
| CEP (ordered patterns) | No | No | Yes — FlinkCEP |
| Stateful stream joins | Limited | No | Yes — interval joins |
| Out-of-order event handling | No | No | Yes — watermarks |
| Analytics query speed | N/A | ~800ms | ~12ms (ClickHouse) |
| Compliance audit trail | No | Yes | Yes (ClickHouse TTL) |
| Operational complexity | Very low | Medium | High |
| Nightly destroy/rebuild | Stateless ✓ | Loses data | Kafka offsets persist* |
| Cost/month (10h/day) | ~$0 | ~$82 | ~$120 (Kafka+Flink+CH) |
| Right for this project now | Yes | Yes | Overkill for lab |

*Kafka needs a PVC to persist offsets — one small PVC vs three large OpenSearch PVCs.

---

### When to use Flink + ClickHouse

**Use it when:**
- You need ordered sequence detection (A then B then C)
- You need absence detection (alert if something does NOT happen)
- You need cross-stream joins with late-arrival tolerance
- Query performance on large historical datasets matters (dashboards feel instant)
- Compliance requires an immutable, queryable audit trail
- Scaling beyond ~20 agents / high event throughput

**Stick with Vector or OpenSearch when:**
- Lab or small deployment (< 10 agents)
- Simple threshold and same-source correlation is enough
- You want minimal operational overhead
- Nightly destroy/rebuild is the primary workflow

---

### Learning resources — Flink

- Flink documentation: https://nightlies.apache.org/flink/flink-docs-stable
- FlinkCEP guide: https://nightlies.apache.org/flink/flink-docs-stable/docs/libs/cep
- Flink Kubernetes Operator: https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-stable
- PyFlink API: https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/python/overview
- Stateful stream processing concepts: https://flink.apache.org/learn-flink/streaming_analytics

### Learning resources — ClickHouse

- ClickHouse docs: https://clickhouse.com/docs
- MergeTree engine (core storage): https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/mergetree
- LowCardinality optimization: https://clickhouse.com/docs/en/sql-reference/data-types/lowcardinality
- Grafana ClickHouse plugin: https://github.com/grafana/clickhouse-datasource
- ClickHouse Helm chart (official): https://github.com/clickhouse/charts

---

## Flink + ClickHouse — Full Cost, Deployment & Licensing Guide

### Licensing

Everything in the Flink + ClickHouse + Kafka stack is fully open-source.
No licence fees, no enterprise tier required for the capabilities described here.

| Component | Licence | Enterprise option |
|---|---|---|
| Apache Flink | Apache 2.0 — free forever | Confluent, Ververica Platform (paid support) |
| Apache Kafka | Apache 2.0 — free forever | Confluent Cloud / MSK (managed, paid) |
| ClickHouse | Apache 2.0 — free forever | ClickHouse Cloud (managed, pay-per-use) |
| Flink Kubernetes Operator | Apache 2.0 — free forever | — |
| Grafana ClickHouse plugin | Apache 2.0 — free forever | — |

No licence cost at any scale. You pay only for compute and storage.

---

### Where it can be deployed

**Option A — Self-hosted on EKS (what this project uses)**
All components run as pods on the existing EKS cluster. Kafka and ClickHouse
need small PVCs for durability. Flink is stateless between restarts if using
Kafka as the state buffer.

**Option B — Fully managed (zero ops)**

| Component | Managed service | Cost model |
|---|---|---|
| Kafka | AWS MSK Serverless | Per GB ingested + per CU/hour |
| Flink | AWS Kinesis Data Analytics (Flink runtime) | Per KPU/hour (~$0.11/KPU) |
| ClickHouse | ClickHouse Cloud | Per GB storage + compute credits |

Managed removes operational burden entirely but costs 3-5x more than self-hosted.
Good for production. Self-hosted on EKS is fine for lab and staging.

**Option C — Hybrid**
Kafka on MSK (managed, durable) + Flink and ClickHouse self-hosted on EKS.
Best of both — Kafka survives cluster destroys, Flink/ClickHouse rebuild quickly.

---

### Resource requirements — self-hosted on EKS

#### Apache Kafka (3-broker cluster, minimum)

| Resource | Per broker | Total (3 brokers) |
|---|---|---|
| CPU request | 500m | 1.5 cores |
| RAM request | 2 Gi | 6 Gi |
| EBS storage | 20 Gi | 60 Gi |
| Node type fits | t3.medium (4GB) | 3 × t3.medium |

At this project's event volume (10 agents, lab workload), 20 Gi per broker
holds ~7 days of events at default 7-day retention. Can reduce to 5 Gi if
nightly destroy is in place (1 day retention sufficient).

#### Apache Flink (1 JobManager + 2 TaskManagers)

| Component | Replicas | CPU | RAM | Storage |
|---|---|---|---|---|
| JobManager | 1 | 0.5 core | 1 Gi | None (stateless) |
| TaskManager | 2 | 1 core | 2 Gi each | None (stateless) |
| Flink Operator | 1 | 0.2 core | 256 Mi | None |
| **Total** | | **2.7 cores** | **5.25 Gi** | **0** |

Flink is fully stateless — all state is in Kafka offsets and ClickHouse.
No PVC needed. Restarts instantly on cluster rebuild.

Fits on the existing `system` nodegroup (t3.medium, 4 GB RAM per node).
Spread across 2-3 system nodes, no dedicated nodegroup needed.

#### ClickHouse (single node for lab)

| Resource | Lab (single node) | Production (3 nodes) |
|---|---|---|
| CPU | 1 core | 2 cores each |
| RAM | 4 Gi | 8 Gi each |
| EBS storage | 30 Gi | 100 Gi each |
| Node fits on | t3.medium | r6g.large |

For this project (lab, nightly destroy) a single ClickHouse node with 30 Gi
is more than enough. TTL auto-deletes data older than 1 day so 30 Gi never fills.

Single-node ClickHouse has no replication — fine for a lab where data is
regenerated daily. For production use 3 nodes with ReplicatedMergeTree.

#### Total cluster resource footprint (self-hosted, lab)

| Component | Additional CPU | Additional RAM | Additional EBS |
|---|---|---|---|
| Kafka (3 brokers) | 1.5 cores | 6 Gi | 60 Gi |
| Flink (JM + 2 TM + operator) | 2.7 cores | 5.25 Gi | 0 |
| ClickHouse (single node) | 1 core | 4 Gi | 30 Gi |
| **Total added** | **5.2 cores** | **15.25 Gi** | **90 Gi** |

This fits across the existing 3 `system` nodes (t3.medium, 2 vCPU / 4 GB each)
without adding any new nodegroup — the system nodegroup currently uses ~40% capacity.

---

### Storage requirements

| Component | Volume | Purpose | Survives nightly destroy? |
|---|---|---|---|
| Kafka broker × 3 | 20 Gi each (60 Gi total) | Event log buffer, 1-day retention | Must use EBS — destroyed nightly |
| ClickHouse | 30 Gi | Correlated events, 1-day TTL | Must use EBS — destroyed nightly |
| Flink | 0 | Stateless — state in Kafka | N/A |
| **Total EBS** | **90 Gi** | | |

EBS cost for 90 Gi at gp2 pricing: **~$9/month** (destroyed nightly — no charge between rebuilds).

If using Hybrid option (Kafka on MSK): MSK Serverless storage is ~$0.10/GB/month.
60 Gi on MSK = ~$6/month, persists across cluster destroys, Flink reconnects automatically.

---

### Cost breakdown — self-hosted on EKS (lab, 10h/day)

The Flink + Kafka + ClickHouse stack fits on existing nodes — no new EC2 required
for a lab workload. Cost is EBS only.

| Resource | Cost/month |
|---|---|
| Kafka EBS (60 Gi, destroyed nightly) | ~$6 |
| ClickHouse EBS (30 Gi, destroyed nightly) | ~$3 |
| EC2 (no new nodes needed — fits on system nodegroup) | $0 extra |
| **Total added cost** | **~$9/month** |

---

### Cost breakdown — all options side by side (lab, 10h/day, nightly destroy)

| Stack | EC2 added | EBS | Licence | Total added/month |
|---|---|---|---|---|
| Grafana Alerting only | $0 | $0 | Free | **$0** |
| Vector (1 pod) | $0 | $0 | Free (MPL-2.0) | **~$0** |
| OpenSearch (3 nodes, 30Gi) | ~$73 | ~$9 | Free (Apache 2.0) | **~$82** |
| **Flink + Kafka + ClickHouse** | **$0** | **~$9** | **Free** | **~$9** |
| AWS EventBridge + CloudWatch | $0 | $0 | Pay-per-event | **~$1** |
| Kafka on MSK + Flink + ClickHouse | $0 | ~$3 (CH only) | Free + MSK ~$6 | **~$9** |

Flink + ClickHouse is **9x cheaper than OpenSearch** for a lab setup because it
fits on existing nodes. OpenSearch needs 3 dedicated nodes (~$73/month EC2).

---

### Cost breakdown — production (24/7, 3 AZ, HA)

| Stack | EC2/month | EBS/month | Licence | Total/month |
|---|---|---|---|---|
| Grafana Alerting only | $0 | $0 | Free | **$0** |
| Vector | $0 | $0 | Free | **~$0** |
| OpenSearch (3 × r6g.large, 100Gi) | ~$175 | ~$30 | Free | **~$205** |
| **Flink + Kafka + ClickHouse (self-hosted)** | **~$120** (3×r6g.large for Kafka+CH) | **~$30** | **Free** | **~$150** |
| Kafka MSK + Flink (KDA) + ClickHouse Cloud | $0 EC2 | $0 EBS | Free | **~$300–500** (fully managed) |

In production Flink + ClickHouse is slightly more expensive than OpenSearch
because Kafka needs dedicated brokers. But you get significantly more capability:
CEP, stateful joins, watermarks, and 50x faster analytics queries.

---

### Nightly destroy/rebuild behaviour

| Component | On destroy | On rebuild | Time to resume |
|---|---|---|---|
| Kafka (EBS) | PVC deleted, offsets lost | Fresh broker, Flink reads from latest | Immediate |
| Flink | Pod deleted, no state lost | Starts fresh, reads from Kafka | ~30s |
| ClickHouse (EBS) | PVC deleted, data gone | Empty DB, TTL not needed | ~60s |
| Schema/tables | Gone | Re-created by hook script on deploy | ~10s |

All three components start cleanly on every rebuild. No manual intervention.
The helmfile hook creates ClickHouse tables and Kafka topics on every postsync.

Compare with OpenSearch: same behaviour — data gone nightly, rules reloaded by hook.
Flink is simpler because there are no "correlation rules" to reload — the CEP patterns
are compiled into the Flink job JAR which is always present in the container image.

---

### Summary — which to pick

| Scenario | Recommendation | Monthly cost |
|---|---|---|
| Lab, nightly destroy, simple rules | Vector + Grafana Alerting | ~$0 |
| Lab, nightly destroy, cross-source correlation | **Flink + ClickHouse** | **~$9** |
| Production, compliance required, SIEM UI needed | OpenSearch | ~$205 |
| Production, high throughput, fast analytics | Flink + ClickHouse | ~$150 |
| Zero ops, fully managed | Kafka MSK + KDA Flink + ClickHouse Cloud | ~$300–500 |

For this project specifically — if you want cross-source correlation without
spending $82/month on OpenSearch, **Flink + ClickHouse at ~$9/month is the
right call**. Same nightly destroy workflow, no new EC2 nodes, open-source.

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
