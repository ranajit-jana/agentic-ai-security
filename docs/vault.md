# Vault Operations Guide

## Architecture

- **3-node HA Raft cluster** (`vault-0`, `vault-1`, `vault-2`) in the `infra` namespace
- **AWS KMS auto-unseal** — no manual unseal needed on pod restart or node failure
- **Recovery keys (Shamir)** — 5 keys, threshold 3 — only needed if the KMS key is lost
- KMS key ID: `09bab559-b3ab-45f4-a437-d3b32aed7fbc` (region: `ap-south-1`)
- Raft followers auto-discover the leader via `retry_join` pointing at `vault-0.vault-internal:8200`

---

## Fresh Cluster Deployment

Vault is deployed and initialised automatically as part of `bash scripts/04_helmfile_deploy.sh`.

The `vault-init.sh` postsync hook handles everything:

1. Waits for `vault-0` to be `Running`
2. Runs `vault operator init -recovery-shares=5 -recovery-threshold=3`
3. **Writes the 5 recovery keys + root token to `~/vault-init-keys-<timestamp>.txt`** (chmod 600)
4. Prints them to the console
5. Saves them to a Kubernetes Secret `vault-init-keys` in the `infra` namespace as a backup
6. **Pauses** — prints `>>> Press Enter ONLY after you have saved ALL 5 recovery keys and the root token:`
7. After you press Enter — enables Kubernetes auth backend and KV v2 secrets engine

### What to do at the pause

1. Open `~/vault-init-keys-<timestamp>.txt`
2. Save all 5 recovery keys and the root token to your password manager
3. Press **Enter** (Return key) to let the script continue
4. After the deploy completes, clean up:
   ```bash
   kubectl delete secret vault-init-keys -n infra
   rm ~/vault-init-keys-*.txt
   ```

### What the keys are for

| Key | Purpose | When needed |
|-----|---------|-------------|
| Root token | Configuring Vault (policies, roles, etc.) | Initial setup and admin tasks |
| 5 recovery keys (3-of-5 threshold) | Disaster recovery only | If the KMS key is ever deleted or lost |

KMS handles every day-to-day unseal automatically. You will likely never need the recovery keys in normal operation.

---

## Checking Vault Status

```bash
# All pods should be 1/1 Running
kubectl get pods -n infra -l app.kubernetes.io/name=vault

# Vault status (initialized + sealed=false)
kubectl exec -n infra vault-0 -- vault status
```

Expected output:
```
initialized  true
sealed       false
ha_enabled   true
active_time  <timestamp>
```

---

## Retrieving Keys if the Terminal Scrolled Past

Keys are saved in three places during init:

**1. File on the deploy machine:**
```bash
ls ~/vault-init-keys-*.txt
cat ~/vault-init-keys-<timestamp>.txt
```

**2. Kubernetes Secret (until you delete it):**
```bash
kubectl get secret vault-init-keys -n infra \
  -o jsonpath='{.data.init-output}' | base64 -d
```

---

## Re-initialising Vault (fresh start)

Only needed if you need to regenerate keys or start completely clean.

```bash
# 1. Scale down so pods release PVCs
kubectl scale statefulset vault -n infra --replicas=0

# 2. Delete PVCs (this wipes all Vault data)
kubectl delete pvc -n infra data-vault-0 data-vault-1 data-vault-2

# 3. Scale back up
kubectl scale statefulset vault -n infra --replicas=3

# 4. Wait for vault-0 to be Running (0/1 is fine — not Ready yet)
kubectl get pods -n infra -l app.kubernetes.io/name=vault -w

# 5. Run the init hook manually
bash helmfile/phase1/hooks/vault-init.sh

# 6. Continue the rest of the stack
bash scripts/04_helmfile_deploy.sh
```

---

## Troubleshooting

### vault-1 / vault-2 stuck at 0/1

The `vault-init.sh` hook explicitly joins followers after vault-0 is Ready, and `values/vault.yaml` also has `retry_join` configured for passive auto-discovery. Both should prevent this. If it still occurs:

```bash
kubectl exec -n infra vault-1 -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -n infra vault-2 -- vault operator raft join http://vault-0.vault-internal:8200
```

### PVC delete stuck in Terminating

The StatefulSet is recreating pods which re-mount the PVCs. Scale down first:

```bash
kubectl scale statefulset vault -n infra --replicas=0
# Wait ~10s, then the kubectl delete pvc command will unblock
```

### Need a new root token (lost original)

Requires 3 of the 5 recovery keys:

```bash
# On vault-0 — follow the interactive prompts
kubectl exec -it -n infra vault-0 -- vault operator generate-root
```

### Vault sealed after KMS issue

If KMS is temporarily unreachable, Vault will re-seal. It will auto-unseal once KMS is reachable again — no manual action needed.
