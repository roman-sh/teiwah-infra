#!/usr/bin/env bash
set -euo pipefail

# Rollout-restart every session worker deployment that uses the GHCR worker image.
# Run after nestwaileys CI publishes a new :amd64 image. Requires imagePullPolicy: Always
# on the deployment (set by teiwah-control) so the node re-pulls the tag.
#
# Usage (on teiwah-master):
#   WORKER_IMAGE=ghcr.io/roman-sh/teiwah-worker bash scripts/worker-restart-all.sh

NAMESPACE="${NAMESPACE:-default}"
WORKER_IMAGE="${WORKER_IMAGE:-ghcr.io/roman-sh/teiwah-worker}"

echo "Restarting deployments in ${NAMESPACE} with image matching ${WORKER_IMAGE}..."

found=0
for deploy in $(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  image=$(kubectl get deployment "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')
  case "$image" in
    "${WORKER_IMAGE}"*|"${WORKER_IMAGE}@"*)
      found=1
      echo "  -> $deploy ($image)"
      kubectl rollout restart "deployment/${deploy}" -n "$NAMESPACE"
      ;;
  esac
done

if [ "$found" -eq 0 ]; then
  echo "No matching deployments found."
  exit 0
fi

for deploy in $(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  image=$(kubectl get deployment "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')
  case "$image" in
    "${WORKER_IMAGE}"*|"${WORKER_IMAGE}@"*)
      kubectl rollout status "deployment/${deploy}" -n "$NAMESPACE" --timeout=120s
      ;;
  esac
done

echo "Done. Auth on the session PVC survives same-node restarts; node moves need QR scan."
