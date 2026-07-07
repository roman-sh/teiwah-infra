#!/usr/bin/env bash
set -euo pipefail

# Remove all session worker resources from a namespace, including per-session
# local-path PVCs named <sessionId> that hold Baileys auth state.
# Does NOT touch traefik-catchall (global-cors, catchall-router, empty-fallback-service).
# Does NOT clear the DB — run DELETE FROM "Session"; separately if needed.
#
# Defaults to the dev namespace (sandbox). Pass a namespace to target prod:
#   scripts/cleanup-sessions.sh            # -> sandbox (dev)
#   scripts/cleanup-sessions.sh default    # -> default (prod)
#   NAMESPACE=default scripts/cleanup-sessions.sh

NAMESPACE="${1:-${NAMESPACE:-sandbox}}"

echo "Searching for session resources in ${NAMESPACE}..."

DEPLOYMENT_IDS=$(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

# Orphan PVCs can remain if a deployment was removed without deleteSessionWorker.
PVC_SESSION_IDS=$(
  kubectl get pvc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | sed 's/-storage$//' \
    | tr '\n' ' ' \
    || true
)
# sed above: legacy PVCs were named <sessionId>-storage; drop once old PVCs are gone.

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
  kubectl delete pvc "$SESSION_ID" -n "$NAMESPACE" --ignore-not-found
  # Legacy PVC name (<sessionId>-storage). Remove this line once old PVCs are gone.
  kubectl delete pvc "${SESSION_ID}-storage" -n "$NAMESPACE" --ignore-not-found
done

echo "Done. Clear DB session rows in Supabase if you want a fresh dashboard list."
