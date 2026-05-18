# Changelog

## [Phase 1 Complete] - 2026-05-18

### Deployed

Full Phase 1 stack — 23/23 validation checks passing.

- Istio 1.29 (mTLS strict, PeerAuthentication enforced)
- Istio Ingress Gateway (AWS NLB, hostname-based routing for all services)
- SPIRE + SPIFFE CSI driver (workload identity, X.509 SVIDs)
- Consul (HA 3-node, ACLs enabled, agent + tool registry seeded)
- Vault (HA Raft 3-node, AWS KMS auto-unseal)
- Keycloak 21 (firm-internal realm, CIBA poll mode enabled)
- CIBA ACP (custom FastAPI backchannel notification service)
- OPA + kube-mgmt (baseline agentic policy, ConfigMap-synced)
- Redis (rate limiting)
- Security Gateway (FastAPI, 2 replicas)
- OTel Collector → Loki → Grafana (full observability stack)
- Agents: orchestrator, web-search, internal-data, report-generation, email

### Fixed

- **Vault**: `vault-init.sh` hook now writes recovery keys to a timestamped file,
  stores them in a Kubernetes Secret, and pauses for operator confirmation before
  continuing — keys can no longer scroll past unnoticed
- **Vault**: Added `retry_join` to Raft storage config so vault-1/vault-2 auto-join
  the leader on fresh cluster creation without manual intervention
- **Vault**: `vault-init.sh` explicitly joins Raft followers and waits for all 3 pods
  to be Ready before enabling auth backends
- **SPIRE**: Agent pods switched from `hostPath` volume to `csi: driver: csi.spiffe.io`
  volume — SPIFFE CSI driver was already deployed but not being used
- **OPA**: Baseline policy rewritten to remove `import future.keywords.if` —
  incompatible with OPA 0.40.0 shipped by kube-mgmt chart 4.1.1
- **OPA**: Disabled OPA meta-authorization (`authz.enabled: false`) — kube-mgmt's
  default token auth blocked all external policy queries
- **Keycloak hook**: Removed `kubectl port-forward` — now uses `kubectl exec` into
  ciba-acp pod to call Keycloak service endpoint directly
- **Validation script**: Removed `kubectl port-forward` for OPA — now uses
  `kubectl exec` into security-gateway pod hitting `https://opa.infra.svc.cluster.local`
- **Validation script**: Fixed CIBA check — public realm endpoint does not expose
  attributes; switched to `/.well-known/openid-configuration` which includes
  `backchannel_authentication_endpoint` when CIBA is enabled
- **Validation script**: Added `--max-time 10` to all curl calls to prevent hanging

### Added

- `docs/vault.md` — Vault operations guide covering init flow, key recovery,
  re-initialisation, Raft troubleshooting, and PVC deletion procedure
- `helmfile/phase1/values/istio-gateway.yaml` — Istio Ingress Gateway values
  (AWS NLB, internet-facing)
- `helmfile/phase1/manifests/security-gateway-ingress.yaml` — Istio Gateway +
  VirtualServices for all five services (gateway, keycloak, vault, grafana, consul)
