#!/usr/bin/env bash
# Create one Hetzner VM that joins the existing k3s cluster (milestone 1 — no autoscaler).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE} — copy from .env.example and fill in values." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

for var in HCLOUD_TOKEN K3S_URL K3S_TOKEN LOCATION SERVER_TYPE WORKER_NAME NETWORK_NAME; do
  if [[ -z "${!var:-}" ]]; then
    echo "Set ${var} in ${ENV_FILE}" >&2
    exit 1
  fi
done

export HCLOUD_TOKEN

NODE_TOKEN="${K3S_TOKEN}"
MASTER_HOST="${K3S_URL#https://}"
MASTER_HOST="${MASTER_HOST%%/*}"
MASTER_HOST="${MASTER_HOST%%:*}"

CLOUD_INIT="$(mktemp)"
trap 'rm -f "${CLOUD_INIT}"' EXIT

sed \
  -e "s|REPLACE_MASTER_HOST|${MASTER_HOST}|g" \
  -e "s|REPLACE_NODE_TOKEN|${NODE_TOKEN}|g" \
  "${ROOT}/worker-cloud-init.yaml.example" > "${CLOUD_INIT}"

echo "Creating server ${WORKER_NAME} (${SERVER_TYPE} @ ${LOCATION}, network ${NETWORK_NAME})..."
hcloud server create \
  --name "${WORKER_NAME}" \
  --type "${SERVER_TYPE}" \
  --image ubuntu-24.04 \
  --location "${LOCATION}" \
  --network "${NETWORK_NAME}" \
  --user-data-from-file "${CLOUD_INIT}"

echo ""
echo "Wait ~2–5 min, then from a machine with kubeconfig:"
echo "  kubectl get nodes"
echo ""
echo "Expected: teiwah-master + ${WORKER_NAME}"
echo ""
echo "Delete test VM when done:"
echo "  hcloud server delete ${WORKER_NAME}"
