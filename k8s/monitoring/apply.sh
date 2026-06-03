#!/usr/bin/env bash
# Deploy kube-prometheus-stack in AGENT mode → Grafana Cloud (metrics-only).
# Applies to the ACTIVE kubectl context — run it ON teiwah-master (kubectl = prod),
# NOT from a Mac whose default context is k3d-teiwah-dev.
#
# Reads ./secret.env for Grafana Cloud creds (gitignored; see secret.env.example).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ROOT}/secret.env"
NS=monitoring

[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE} (copy secret.env.example)" >&2; exit 1; }
# Export so envsubst (a subprocess) sees the vars.
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

for var in GRAFANA_CLOUD_PROM_URL GRAFANA_CLOUD_USERNAME GRAFANA_CLOUD_API_KEY; do
  [[ -n "${!var:-}" ]] || { echo "Set ${var} in ${ENV_FILE}" >&2; exit 1; }
done

command -v helm >/dev/null || { echo "helm not found on PATH" >&2; exit 1; }

echo "Ensuring namespace ${NS}..."
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "Creating/updating secret grafana-cloud (${NS})..."
kubectl -n "${NS}" create secret generic grafana-cloud \
  --from-literal=username="${GRAFANA_CLOUD_USERNAME}" \
  --from-literal=password="${GRAFANA_CLOUD_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Adding/refreshing prometheus-community helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

# Substitute ONLY the remote_write URL — restricting envsubst keeps Prometheus
# relabel refs like $1 intact.
RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}"' EXIT
envsubst '$GRAFANA_CLOUD_PROM_URL' < "${ROOT}/values.yaml" > "${RENDERED}"

echo "helm upgrade --install kube-prometheus-stack (agent mode)..."
helm upgrade --install teiwah-monitoring prometheus-community/kube-prometheus-stack \
  -n "${NS}" \
  -f "${RENDERED}"

echo ""
echo "Watch it:"
echo "  kubectl -n ${NS} get pods -w"
echo "  kubectl -n ${NS} logs -f -l app.kubernetes.io/name=prometheus-agent"
echo "Then confirm series land in Grafana Cloud → Kubernetes Monitoring."
