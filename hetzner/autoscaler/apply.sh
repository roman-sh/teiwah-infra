#!/usr/bin/env bash
# Deploy the Hetzner Cluster Autoscaler + overprovisioning placeholders.
# Applies to the ACTIVE kubectl context — run it ON teiwah-master (kubectl = prod).
# Do NOT run from a Mac whose default context is k3d-teiwah-dev (it would hit the local
# cluster). For Mac, use the SSH method in README.md "Deploy → Option B".
# Reads ../.env for token/URL/join-token.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HETZNER="$(cd "${ROOT}/.." && pwd)"
ENV_FILE="${HETZNER}/.env"
CLOUD_INIT_TPL="${HETZNER}/worker-cloud-init.yaml.example"

[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${ENV_FILE}"

for var in HCLOUD_TOKEN K3S_URL K3S_TOKEN; do
  [[ -n "${!var:-}" ]] || { echo "Set ${var} in ${ENV_FILE}" >&2; exit 1; }
done

# Master host the agents dial (strip scheme + port from K3S_URL -> 10.0.0.2)
MASTER_HOST="${K3S_URL#https://}"; MASTER_HOST="${MASTER_HOST%%:*}"

# Render the SAME cloud-init used for manual workers, with real values, then base64.
CLOUD_INIT_B64="$(sed \
  -e "s|REPLACE_MASTER_HOST|${MASTER_HOST}|g" \
  -e "s|REPLACE_NODE_TOKEN|${K3S_TOKEN}|g" \
  "${CLOUD_INIT_TPL}" | base64 -w0)"

echo "Creating/updating secret hcloud-autoscaler (kube-system)..."
kubectl -n kube-system create secret generic hcloud-autoscaler \
  --from-literal=token="${HCLOUD_TOKEN}" \
  --from-literal=cloudInit="${CLOUD_INIT_B64}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Applying cluster-autoscaler..."
kubectl apply -f "${ROOT}/cluster-autoscaler.yaml"

echo "Applying overprovisioning placeholders..."
kubectl apply -f "${ROOT}/overprovision.yaml"

echo ""
echo "Watch it:"
echo "  kubectl -n kube-system logs -f deploy/cluster-autoscaler"
echo "  kubectl get nodes -w"
