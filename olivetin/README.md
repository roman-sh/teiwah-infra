# Ops panel (OliveTin)

A tiny web UI of buttons that run the `teiwah-infra` Makefile targets on
`teiwah-master` — the same commands you'd type over SSH, just clickable, with the
output (stdout/stderr, exit code, duration) shown in a dialog.

It is **not** a replacement for k9s (which manages live pods/logs). This is for the
**orchestration scripts** k9s can't run: `sandbox-setup`, `cleanup`,
`worker-restart-all`, etc.

## Security model

- Runs as **root** on `teiwah-master`, so it has **cluster-admin**. Treat the URL
  as the entire security boundary.
- Bound to **`127.0.0.1:1337`** — never directly reachable.
- Exposed only via the **Cloudflare Tunnel** (`infra.teiwah.cloud`) behind
  **Cloudflare Access** (email allow-list). Cloudflare forces login before any
  request reaches it.
- **Do not** publish `:1337` any other way (NodePort, firewall, second ingress).

## Cloudflare (one-time, dashboard — already done)

1. **Tunnel** (Zero Trust → Networks → Tunnels → your tunnel → Public Hostnames):
   add `infra.teiwah.cloud` → Service `HTTP` → `localhost:1337`.
2. **Access** (Zero Trust → Access → Applications → Add → Self-hosted):
   domain `infra.teiwah.cloud`, policy **Allow → Emails → <your email>**.
3. Verify in incognito: `infra.teiwah.cloud` should show a Cloudflare login first.

## Install on teiwah-master

Assumes the repo is at `/root/teiwah-infra` and root's `~/.kube/config` resolves to
the cluster (on k3s it's a symlink to `/etc/rancher/k3s/k3s.yaml`). If the repo
lives elsewhere, update the `make -C` paths in `config.yaml`.

```bash
# 1. Install OliveTin (Debian/Ubuntu .deb from the latest GitHub release).
#    See https://docs.olivetin.app/install/linux.html for the current URL.
#    e.g.
#      curl -L -o olivetin.deb https://github.com/OliveTin/OliveTin/releases/latest/download/OliveTin_linux_amd64.deb
#      apt install ./olivetin.deb

# 2. Point OliveTin at the repo's config (so `git pull` updates the buttons).
ln -sf /root/teiwah-infra/olivetin/config.yaml /etc/OliveTin/config.yaml

# 3. Run it as root (drop-in override). kubectl then uses root's ~/.kube/config
#    (symlinked to the k3s kubeconfig) automatically.
mkdir -p /etc/systemd/system/OliveTin.service.d
cp /root/teiwah-infra/olivetin/olivetin.service.override.conf \
   /etc/systemd/system/OliveTin.service.d/override.conf
systemctl daemon-reload
systemctl enable --now OliveTin
systemctl restart OliveTin

# 4. Sanity check (local) then via the tunnel.
curl -sS http://127.0.0.1:1337/ | head
```

Then open `https://infra.teiwah.cloud`.

## Buttons

| Button | Runs | Args |
|--------|------|------|
| List pods | `make pods NAMESPACE=…` | namespace dropdown |
| Restart all workers | `make worker-restart-all NAMESPACE=…` | namespace dropdown |
| Sandbox setup | `make sandbox-setup` | — |
| Refresh cleanup session list | `make cleanup-list-refresh NS=…` | namespace dropdown |
| FULL HARD DELETE selected sessions | `make cleanup-selected-hard NS=… SESSIONS=…` | namespace dropdown + session checklist + confirm checkbox |

The full cleanup button deletes the Zuplo consumer/API key, k8s resources/PVCs,
and the `sessions` DB row. Demo sessions have no DB/Zuplo records, so those steps
report "not found" and continue.

Before using it on the server, create namespace-specific env files from
`session-cleanup.env.example`:

```bash
mkdir -p /etc/teiwah/session-cleanup
cp /root/teiwah-infra/olivetin/session-cleanup.env.example /etc/teiwah/session-cleanup/sandbox.env
cp /root/teiwah-infra/olivetin/session-cleanup.env.example /etc/teiwah/session-cleanup/default.env
```

`sandbox.env` must point at the dev DB + dev Zuplo bucket and set
`CLEANUP_NAMESPACE=sandbox`; `default.env` must point at prod and set
`CLEANUP_NAMESPACE=default`.

## Adding / changing buttons

Edit `config.yaml`, commit, `git pull` on the server. OliveTin live-reloads most
changes; `systemctl restart OliveTin` if a change doesn't take.

The panel deliberately uses only **dropdown**, generated **checklist**, and
**confirmation** inputs (no free-text), so arguments stay constrained. If you add
a free-text argument later (e.g. a session id for a single-pod restart), constrain
its `type` and be aware it runs as root.
