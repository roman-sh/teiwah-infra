# Monitoring — kube-prometheus-stack (agent) → Grafana Cloud

Metrics-only, low-footprint capacity planning for the teiwah k3s cluster.
Grafana Cloud is the **store, dashboards, and alerting**; the cluster just runs a
Prometheus **agent** (remote_write, no local TSDB), `kube-state-metrics`, and a
`node-exporter` DaemonSet. No local Grafana, no Alertmanager, no PVC.

## Why this shape

The cluster is small (4 GB cx23/cpx22 nodes) and request-driven autoscaling means the
real capacity lever is the **session pod memory request** (`160Mi`, set in
`teiwah-control/src/k8s.service.ts`). The job here is to measure actual usage so that
request can be right-sized — without a full self-hosted Prometheus eating the same RAM.

| File | Purpose |
|------|---------|
| `values.yaml` | kube-prometheus-stack in agent mode: k3s disables, remote_write, master pinning, autoscaler scrape |
| `secret.env.example` | Grafana Cloud push URL + username + write token (copy to `secret.env`, gitignored) |
| `apply.sh` | Creates the `grafana-cloud` secret + `helm upgrade --install` |

## Deploy

Run on **`teiwah-master`** (active kubectl = prod), not from a Mac on `k3d-teiwah-dev`.

```bash
cd ~/teiwah-infra/k8s/monitoring   # git pull first
cp secret.env.example secret.env   # fill in Grafana Cloud creds
bash apply.sh
# or from repo root: make monitoring
```

Requires `helm` and `envsubst` (gettext) on the master.

## Verify

```bash
make monitoring-status
kubectl -n monitoring get pods -o wide
```

Tail the agent: `kubectl -n monitoring logs -f -l app.kubernetes.io/name=prometheus-agent`.

Expect: one `prometheus-agent` + `kube-state-metrics` on `teiwah-master`, and a
`node-exporter` pod on every node (including autoscaled ones). Then in Grafana Cloud →
Kubernetes Monitoring, confirm `{cluster="teiwah"}` series are arriving.

## The queries that matter (run in Grafana Cloud Explore)

**RAM per session** — actual working set per session pod:

```promql
sum(container_memory_working_set_bytes{namespace="default", container="wa-session"}) by (pod)
```

P75 across sessions (use this to set the request in `k8s.service.ts`):

```promql
quantile(0.75, sum(container_memory_working_set_bytes{container="wa-session"}) by (pod))
```

**Sessions per worker** — pod count per node:

```promql
count(kube_pod_info{namespace="default"}) by (node)
```

**When should the autoscaler scale** — requested memory vs allocatable per node:

```promql
sum(kube_pod_container_resource_requests{resource="memory"}) by (node)
  / sum(kube_node_status_allocatable{resource="memory"}) by (node)
```

**Did a node crash** — node-exporter target down / NotReady:

```promql
up{job=~".*node-exporter.*"} == 0
kube_node_status_condition{condition="Ready", status="true"} == 0
```

**Did a pod restart / OOMKill** (watch this against the `224Mi` limit):

```promql
increase(kube_pod_container_status_restarts_total{namespace="default"}[1h])
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}
```

**Why is provisioning slow** — from the cluster-autoscaler scrape:

```promql
cluster_autoscaler_unschedulable_pods_count
cluster_autoscaler_nodes_count
histogram_quantile(0.9, rate(cluster_autoscaler_function_duration_seconds_bucket{function="ScaleUp"}[15m]))
```

## Tuning / cost

- **Sample volume:** `scrapeInterval: 60s` keeps Grafana Cloud active-series cost low. Drop
  to `30s` only if autoscaler timing needs finer resolution.
- **Active-series allowlist (required for Grafana Cloud free tier):** the stock stack ships
  tens of thousands of series (cAdvisor/ksm/node-exporter) and blows past Grafana Cloud's
  ~10k free-tier cap. `remoteWrite[].writeRelabelConfigs` keeps only the metric names the
  dashboard + alerts use, so we *scrape* everything locally but *ship* a few hundred series.
  Add a metric name to that `keep` regex in `values.yaml` if a new panel/alert needs it.
- **Alerting/logs:** define alerts in Grafana Cloud (node down, OOMKill spike, autoscaler
  stuck). Logs (Loki/Better Stack) are a later stage — this stack is metrics-only by design.

## Notes

- k3s runs control-plane components as one embedded process, so the chart's
  `kubeScheduler/kubeControllerManager/kubeProxy/kubeEtcd` scrape jobs are **disabled** —
  they'd only error. kubelet/cAdvisor (pod memory) and node-exporter work natively.
- The agent, operator, and kube-state-metrics are pinned to `teiwah-master` (like HCCM /
  cluster-autoscaler) so monitoring never lands on a paid session node or triggers scale-up.
- `node-exporter` tolerates all taints so new autoscaled nodes report node memory on join.
