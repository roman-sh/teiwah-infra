# Teiwah Infrastructure

**Central ops runbook** for Teiwah — deploy pipelines, Hetzner k8s, Traefik, GHCR, and day-2 commands. Product behavior: [DESIGN.md](../DESIGN.md), [TEIWAH_ARCHITECTURE.md](../TEIWAH_ARCHITECTURE.md).

---

## Deploy pipelines (all repos)

| Repo | Artifact | How it ships | After deploy |
|------|----------|--------------|--------------|
| **nestwaileys** | Worker Docker image | GitHub Actions → GHCR | Restart session pods on k8s (below) |
| **teiwah-zuplo** | API gateway routes/policies | GitHub → Zuplo (push `main`) | Check Zuplo logs; sync `ZUPLO_ORIGIN` on CF Worker if gateway URL changed |
| **teiwah-control** | Control Nest app | Coolify (manual deploy) | Health: `https://control.teiwah.cloud/health` |
| **teiwah-board** | Dashboard | Vercel (push `main`) | — |

**Hostnames (production):**

| Host | Path |
|------|------|
| `api.teiwah.cloud` | CF Worker → Zuplo → control or k3s |
| `control.teiwah.cloud` | Tunnel → teiwah-control |
| `k3s.teiwah.cloud` | Tunnel → Traefik → session pods |
| `n8n.teiwah.cloud` | User automation (webhooks) |

---

## Worker image — nestwaileys → GHCR

**Image:** `ghcr.io/roman-sh/teiwah-worker:amd64` (must match control `SESSION_WORKER_IMAGE`).

**CI:** `nestwaileys/.github/workflows/docker-publish.yml`

- Triggers: push to `main`, `workflow_dispatch`
- Platform: `linux/amd64`
- Tags: `:amd64`, `:<git-sha>`
- **Does not restart pods**

**After a green Actions run** (on `teiwah-master`, this repo):

```bash
cd ~/teiwah-infra
make worker-restart-all
# or one session:
make worker-restart SESSION=<session-id>
```

**First-time / pull secret:** `k8s/secrets/.env` → `make ghcr-secret` (creates `ghcr-pull` in namespace).

**Manual build/push** (bypass CI, from your Mac):

```bash
cd teiwah-infra
make worker-publish    # buildx push ghcr.io/roman-sh/teiwah-worker:amd64
```

Then `make worker-restart-all` on the cluster.

**Local k3d** (not GHCR): build in `nestwaileys/`, `k3d image import` — see [nestwaileys/README.md](../nestwaileys/README.md).

> Pod restart wipes Baileys auth until PVC exists — expect re-scan QR.

---

## API gateway — teiwah-zuplo → Zuplo

**Repo:** `teiwah-zuplo/` — routes in `config/routes.oas.json`, policies in `config/policies.json`, handlers in `modules/`.

**Deploy:** commit + push `main` → Zuplo production deploys from GitHub.

**Portal (not route source of truth):** env vars `TEIWAH_KEY_BUCKET`, `CLERK_FRONTEND_API_URL` (`teiwah-zuplo/env.example`); request logs; gateway URL.

**Cloudflare Worker** (`api.teiwah.cloud`): variable `ZUPLO_ORIGIN` = current Zuplo gateway URL from portal. Update after gateway redeploy or `POST /messages` hits wrong host (404).

**Bucket alignment:** control `ZUPLO_KEY_BUCKET` and Zuplo `TEIWAH_KEY_BUCKET` must be the same key bucket (Zuplo forbids `ZUPLO_` prefix in portal env names).

---

## Kubernetes (this repo)

Teiwah provisions **one Deployment per session** (control → k8s API). Traefik routes `/sessions/<sessionId>/...` to the pod (per-session strip-prefix middleware).

1. **Traefik catchall** — unmatched `/sessions/...` → **503** + CORS (SSE retries during boot).
2. **Helm values** — `k8s/traefic/values.yaml` (`traefik-k3s` ingress class).
3. **Makefile / scripts** — logs, rollout, cleanup.

```
base/                 # catchall + CORS middleware
overlays/local-k3d/   # local k3d
k8s/traefic/          # Helm values (production)
k8s/secrets/          # GHCR pull secret .env (gitignored)
scripts/              # cleanup, worker-restart-all, create-ghcr-pull-secret
Makefile
```

### Production cluster (Hetzner)

| Node | Role |
|------|------|
| `teiwah-master` | control-plane — k3s API, Coolify, cloudflared, Traefik |
| `teiwah-worker` | worker node — session pods |

**Add workers (existing master, no Terraform):** [hetzner/README.md](./hetzner/README.md) — milestone 1: `hcloud` + cloud-init join proof.

### Worker autoscaling (live)

Cluster Autoscaler (Hetzner provider) + overprovisioning placeholder run in `kube-system`.
Nodes auto-provision on `teiwah-private` as `hcloud://` when load demands, with a whole spare
node kept warm ahead of demand. Setup + tuning: [hetzner/autoscaler/README.md](./hetzner/autoscaler/README.md).

- Cluster uses **external cloud provider** (HCCM) on `teiwah-private` — node config + migration
  notes in [hetzner/README.md](./hetzner/README.md#cluster-networking--external-cloud-provider--teiwah-private).
- Preference: `cx23/cx33` → `cpx22` → `cpx32`, EU-only (`nbg1`/`fsn1`/`hel1`).

```bash
ssh root@178.105.212.172
cd ~/teiwah-infra
```

**Namespace:** `default`

```bash
make pods
make logs SESSION=<session-id>
make catchall          # apply 503 catchall if needed
make traefik           # helm upgrade Traefik
```

### Orphan k8s resources

Session delete in DB does not always remove Ingress/Service/Middleware. Orphan example: Service + Ingress without Deployment.

```bash
make cleanup   # destructive — all session k8s resources
```

---

## Makefile reference

| Target | Description |
|--------|-------------|
| `make pods` | Pods in `NAMESPACE` (default `default`) |
| `make pods-watch` | `kubectl get pods -w` |
| `make pods-live` | Refresh every 2s |
| `make sessions` | Pods + ingresses |
| `make logs SESSION=id` | Follow worker logs |
| `make worker-publish` | Build/push worker image to GHCR (Mac) |
| `make worker-restart SESSION=id` | Rollout restart one deployment |
| `make worker-restart-all` | Restart all worker deployments |
| `make ghcr-secret` | GHCR pull secret in cluster |
| `make traefik` | Helm upgrade Traefik |
| `make catchall` | Apply 503 catchall |
| `make cleanup` | Delete all session k8s resources |

### Local k3d

```bash
kubectl apply -k overlays/local-k3d
```
