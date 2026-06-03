# Hetzner worker scaling (existing cluster)

**Prerequisite:** `teiwah-master` + `teiwah-worker` already running. Do **not** recreate the master.

**Milestone 1 (done):** prove one new worker via `hcloud` + cloud-init (no UI, no Terraform, no autoscaler).

**Milestone 2 + 3 (done — live on prod):** Cluster Autoscaler + Hetzner provider runs the same
cloud-init when load demands it, plus an overprovisioning placeholder that keeps a whole spare
node warm. See [autoscaler/README.md](./autoscaler/README.md).

Reference: [Hetzner — k3s autoscaling](https://community.hetzner.com/tutorials/deploy-k3s-on-hetzner-with-autoscaling)

---

## Cluster networking — external cloud provider + teiwah-private

The cluster runs k3s with the **Hetzner Cloud Controller Manager (HCCM)** in external mode.
All traffic (control plane, kubelet, and pod-to-pod overlay) flows over **teiwah-private** (`10.0.0.0/16`).

| Node | ProviderID | Private (InternalIP) | Public (ExternalIP) |
|------|------------|----------------------|---------------------|
| `teiwah-master` | `hcloud://...` | `10.0.0.2` | `178.105.212.172` |
| `teiwah-worker` | `hcloud://...` | `10.0.0.3` | `178.104.201.94` |

**Per-node config** (`/etc/rancher/k3s/config.yaml`, survives k3s upgrades):

```yaml
# master
disable-cloud-controller: true      # stop k3s embedded CCM (it races HCCM for ProviderID)
node-ip: 10.0.0.2                    # private; also fixes kubelet serving-cert SANs
node-external-ip: 178.105.212.172
flannel-iface: enp7s0               # pod VXLAN over teiwah-private
kubelet-arg:
  - cloud-provider=external          # HCCM assigns hcloud:// ProviderID on registration
```

```yaml
# worker (no disable-cloud-controller; node-ip = its own 10.0.0.x)
node-ip: 10.0.0.3
node-external-ip: 178.104.201.94
flannel-iface: enp7s0
kubelet-arg:
  - cloud-provider=external
```

**HCCM** is Helm-installed in `kube-system` (secret `hcloud`: `token` + `network`=teiwah-private ID).
It carries `HCLOUD_NETWORK` (→ private InternalIP) and `HCLOUD_NETWORK_ROUTES_ENABLED=false`
(routing left to flannel). Tutorial equivalent: `ccm-networks.yaml`.

> Existing nodes were migrated one-time (`kubectl delete node` + restart) because ProviderID is
> immutable. **New/autoscaled nodes need no migration** — the flags are baked into
> `worker-cloud-init.yaml.example`, so they register as `hcloud://` on the private network directly.

---

## Milestone 1 — manual proof

### On teiwah-master

```bash
# Node join token (keep secret)
cat /var/lib/rancher/k3s/server/node-token

# Use the IP/hostname workers use to reach the API (often master public or private IP)
# K3S_URL example: https://10.0.0.2:6443  or  https://<public-ip>:6443
```

Ensure **port 6443** on the master is reachable from a new Hetzner VM in the same location/network.

### On your laptop

```bash
brew install hcloud   # if needed
hcloud context create teiwah   # paste API token (Read & Write)

cd teiwah-infra/hetzner
cp .env.example .env
# edit .env: HCLOUD_TOKEN, K3S_URL, K3S_TOKEN, LOCATION, SERVER_TYPE, WORKER_NAME, NETWORK_NAME

chmod +x create-test-worker.sh
./create-test-worker.sh
```

Or one-shot without the script:

```bash
export HCLOUD_TOKEN=...
# edit worker-cloud-init.yaml from worker-cloud-init.yaml.example (replace placeholders)

hcloud server create \
  --name teiwah-worker-test-1 \
  --type cpx22 \
  --image ubuntu-24.04 \
  --location nbg1 \
  --network teiwah-private \
  --user-data-from-file worker-cloud-init.yaml
```

### Verify

```bash
kubectl get nodes -o wide
```

Expected:

```text
teiwah-master          Ready    control-plane
teiwah-worker-test-1   Ready    <none>
```

(Optional) label for session scheduling:

```bash
kubectl label node teiwah-worker-test-1 teiwah-role=session-worker
```

### Cleanup test VM

```bash
hcloud server delete teiwah-worker-test-1
# If the node object remains:
kubectl delete node teiwah-worker-test-1
```

---

## Milestone 2 — Cluster Autoscaler (later)

Same `worker-cloud-init` content → base64 in `kube-system` secret → Hetzner cluster-autoscaler deployment. Autoscaler replaces `./create-test-worker.sh` at runtime.

---

## Milestone 3 — overprovisioning (later)

10 low-priority pause pods @ same requests as session worker (~164Mi). Real session pods preempt them; Pending placeholders trigger scale-up.
