#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/k8s/secrets/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing ${ENV_FILE}"
  echo "Run: cp k8s/secrets/.env.example k8s/secrets/.env"
  echo "Then set GHCR_PAT (classic token with read:packages)."
  exit 1
fi

# Caller-provided env (e.g. K8S_NAMESPACE=sandbox) must win over .env defaults,
# since sourcing the file below would otherwise clobber it.
_OVERRIDE_NS="${K8S_NAMESPACE:-}"
_OVERRIDE_SECRET="${SECRET_NAME:-}"

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${GHCR_USERNAME:?Set GHCR_USERNAME in k8s/secrets/.env}"
: "${GHCR_PAT:?Set GHCR_PAT in k8s/secrets/.env}"
K8S_NAMESPACE="${_OVERRIDE_NS:-${K8S_NAMESPACE:-default}}"
SECRET_NAME="${_OVERRIDE_SECRET:-${SECRET_NAME:-ghcr-pull}}"

kubectl create secret docker-registry "$SECRET_NAME" \
  -n "$K8S_NAMESPACE" \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USERNAME" \
  --docker-password="$GHCR_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "OK: secret ${SECRET_NAME} in namespace ${K8S_NAMESPACE}"
echo "Set IMAGE_PULL_SECRET=${SECRET_NAME} on teiwah-control (Coolify) and redeploy."
