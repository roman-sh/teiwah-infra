#!/usr/bin/env bash
set -euo pipefail

# Remove all session worker resources from k3s (default namespace).
# Does NOT touch traefik-catchall (global-cors, catchall-router, empty-fallback-service).
# Does NOT clear Supabase — run DELETE FROM "Session"; separately if needed.
#
# Usage (on teiwah-master):
#   ~/teiwah-infra/scripts/cleanup-sessions.sh

NAMESPACE="${NAMESPACE:-default}"

echo "Searching for session deployments in ${NAMESPACE}..."

SESSION_IDS=$(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

if [ -z "$SESSION_IDS" ]; then
  echo "No session deployments found."
  exit 0
fi

for SESSION_ID in $SESSION_IDS; do
  echo "Cleaning up: $SESSION_ID"
  kubectl delete deployment "$SESSION_ID" -n "$NAMESPACE" --ignore-not-found
  kubectl delete service "$SESSION_ID" -n "$NAMESPACE" --ignore-not-found
  kubectl delete ingress "$SESSION_ID" -n "$NAMESPACE" --ignore-not-found
  kubectl delete middleware "${SESSION_ID}-strip" -n "$NAMESPACE" --ignore-not-found
done

echo "Done. Clear DB session rows in Supabase if you want a fresh dashboard list."
