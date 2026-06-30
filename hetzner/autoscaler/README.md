# Cluster Autoscaler + overprovisioning (teiwah)

Automated worker nodes for the existing k3s cluster. Prereqs already done:
external cloud provider (HCCM, `hcloud://` ProviderIDs) + `teiwah-private` networking
— see [../README.md](../README.md).

## What this deploys

| File | Purpose |
|------|---------|
| `cluster-autoscaler.yaml` | Autoscaler Deployment + RBAC + priority expander ConfigMap |
| `overprovision.yaml` | Placeholder pause pods (instant headroom while a VM boots) |
| `apply.sh` | Renders cloud-init, creates the `hcloud-autoscaler` secret, applies both |

## Preference (pure config — availability handled at runtime)

```text
tier 1: cx23, cx33   @ nbg1 / fsn1 / hel1
tier 2: cpx22        @ nbg1 / fsn1 / hel1
tier 3: cpx32        @ nbg1 / fsn1 / hel1
```

- EU-only: only `eu-central` servers can attach to `teiwah-private`.
- If a type/region can't be created, the autoscaler backs that pool off and the priority
  expander falls to the next tier. No availability assumptions baked in.
- `max=250`/pool ≈ uncapped. Real ceiling = your **Hetzner project server quota**
  (raise via Hetzner support as you grow).

## Deploy

`apply.sh` targets whatever `kubectl` context is active, so it must run against the **prod**
cluster — **not** a local dev context.

**Option A — on `teiwah-master`** (kubectl is prod natively):

```bash
cd ~/teiwah-infra/hetzner/autoscaler   # git pull first
bash apply.sh
```

**Option B — from your Mac over SSH** (the Mac has no prod kubeconfig; its default context is
`k3d-teiwah-dev`, so a plain `bash apply.sh` would wrongly hit the local cluster). Render the
secret locally and pipe manifests to the master:

```bash
cd teiwah-infra/hetzner
source .env
MASTER_HOST="${K3S_URL#https://}"; MASTER_HOST="${MASTER_HOST%%:*}"
CLOUD_INIT_B64="$(sed -e "s|REPLACE_MASTER_HOST|${MASTER_HOST}|g" \
  -e "s|REPLACE_NODE_TOKEN|${K3S_TOKEN}|g" worker-cloud-init.yaml.example | base64 | tr -d '\n')"

ssh root@<master-public-ip> "kubectl -n kube-system create secret generic hcloud-autoscaler \
  --from-literal=token='${HCLOUD_TOKEN}' --from-literal=cloudInit='${CLOUD_INIT_B64}' \
  --dry-run=client -o yaml | kubectl apply -f -"

ssh root@<master-public-ip> 'kubectl apply -f -' < autoscaler/cluster-autoscaler.yaml
ssh root@<master-public-ip> 'kubectl apply -f -' < autoscaler/overprovision.yaml
```

## Verify scale-up

```bash
kubectl -n kube-system logs -f deploy/cluster-autoscaler
kubectl get nodes -w

# Force a scale-up (each placeholder ~claims a node, so a few replicas exceeds capacity):
kubectl -n kube-system scale deploy/overprovisioning --replicas=5
# ...watch a node appear, then revert:
kubectl -n kube-system scale deploy/overprovisioning --replicas=1
```

New nodes appear as `teiwah-<pool>-<hash>`, `Ready`, `hcloud://...`, on `teiwah-private`.

## Tuning

- **Buffer size** — current model keeps a **whole spare node** warm: one placeholder sized
  `3Gi/1500m` (~fills a 4 GB / 2 vCPU `cx23`/`cpx22`). `replicas` = number of spare nodes to
  keep ahead of demand. Keep per-pod `memory` ≤ the smallest node's allocatable, or the
  placeholder won't fit there and the cheap tiers get skipped.
- **Scale-down timing** — `--scale-down-unneeded-time` / `--scale-down-delay-after-add`.
- **Image tag** — keep `cluster-autoscaler:v1.<minor>` in sync with the cluster
  (`kubectl version`). Currently v1.35.x.
- **SSH into autoscaled nodes** — uncomment `HCLOUD_SSH_KEY` in `cluster-autoscaler.yaml`.

## Notes / gotchas

- **Kubernetes 1.35+ RBAC** — the ClusterRole must include `resource.k8s.io` (`deviceclasses`,
  `resourceclaims`, `resourceslices`). Without it the autoscaler logs RBAC forbidden spam,
  `cluster_safe_to_autoscale` stays `0`, and overprovisioning placeholders stay Pending with
  no new Hetzner nodes. After updating `cluster-autoscaler.yaml`, `git pull` on
  `teiwah-master` and re-run `apply.sh` (or `kubectl apply -f cluster-autoscaler.yaml` then
  `kubectl -n kube-system rollout restart deploy/cluster-autoscaler`).
- Placeholder priority is `-1` (above the autoscaler's `-10` expendable cutoff) so the
  autoscaler still scales up for them; real session pods (priority 0) preempt them.
- Existing `teiwah-master` / `teiwah-worker` are static — not in any pool, never resized.
- US/Singapore are intentionally excluded: different network zones can't join
  `teiwah-private`, and cross-zone pod traffic would be slow.
