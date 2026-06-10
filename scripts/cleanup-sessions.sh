#!/usr/bin/env bash
set -euo pipefail

# Remove all session worker resources from k3s (default namespace), including
# per-session local-path PVCs (<sessionId>-storage) that hold Baileys auth state.
# Does NOT touch traefik-catchall (global-cors, catchall-router, empty-fallback-service).
# Does NOT clear Supabase — run DELETE FROM "Session"; separately if needed.
#
# Usage (on teiwah-master):
#   ~/teiwah-infra/scripts/cleanup-sessions.sh

NAMESPACE="${NAMESPACE:-default}"

echo "Searching for session resources in ${NAMESPACE}..."

DEPLOYMENT_IDS=$(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

# Orphan PVCs can remain if a deployment was removed without deleteSessionWorker.
PVC_SESSION_IDS=$(
  kubectl get pvc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | sed -n 's/-storage$//p' \
    | tr '\n' ' ' \
    || true
)

SESSION_IDS=$(printf '%s %s\n' "$DEPLOYMENT_IDS" "$PVC_SESSION_IDS" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')

if [ -z "${SESSION_IDS// }" ]; then
  echo "No session deployments or auth PVCs found."
  exit 0
fi

for SESSION_ID in $SESSION_IDS; do
  echo "Cleaning up: $SESSION_ID"
  kubectl delete ingress "$SESSION_ID" -n "$NAMESPACE" --ignore-not-found
  kubectl delete middleware "${SESSION_ID}-strip" -n "$NAMESPACE" --ignore-not-found
  kubectl delete service "$SESSION_ID" -n "$NAMESPACE" --ignore-not-found
  kubectl delete deployment "$SESSION_ID" -n "$NAMESPACE" --ignore-not-found
  kubectl delete pvc "${SESSION_ID}-storage" -n "$NAMESPACE" --ignore-not-found
done

echo "Done. Clear DB session rows in Supabase if you want a fresh dashboard list."
