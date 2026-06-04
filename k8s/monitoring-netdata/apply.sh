#!/usr/bin/env bash
# Deploy Netdata (parent + child DaemonSet + k8sState) as a NON-DESTRUCTIVE trial,
# alongside kube-prometheus-stack. Applies to the ACTIVE kubectl context — run ON
# teiwah-master (kubectl = prod), not from a Mac on k3d-teiwah-dev.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NS=netdata

command -v helm >/dev/null || { echo "helm not found on PATH" >&2; exit 1; }

helm repo add netdata https://netdata.github.io/helmchart/ >/dev/null 2>&1 || true
helm repo update netdata >/dev/null

echo "Ensuring namespace ${NS}..."
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "helm upgrade --install netdata..."
helm upgrade --install netdata netdata/netdata -n "${NS}" -f "${ROOT}/values.yaml"

echo ""
echo "Watch it:  kubectl -n ${NS} get pods -o wide -w"
echo "Open the UI from your Mac (parent serves on :19999):"
echo "  ssh -L 19999:127.0.0.1:19999 root@<master-ip> \\"
echo "    'kubectl -n ${NS} port-forward --address 127.0.0.1 svc/netdata 19999:19999'"
echo "  then browse http://localhost:19999"
echo ""
echo "Teardown (storage is ephemeral, nothing left behind):"
echo "  helm -n ${NS} uninstall netdata && kubectl delete namespace ${NS}"
