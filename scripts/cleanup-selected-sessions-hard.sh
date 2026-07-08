#!/usr/bin/env bash
set -euo pipefail

# Full hard-delete for selected Teiwah sessions.
#
# For every selected session:
#   1. Delete the Zuplo consumer/API key (404 is OK).
#   2. Best-effort POST /disconnect inside the worker pod, if it exists.
#   3. Delete k8s Ingress, Traefik Middleware, Service, Deployment, PVCs.
#   4. Permanently DELETE the DB row from sessions.
#
# The selected list must be comma-separated OliveTin checklist values in the
# form `namespace:sessionId`.

NAMESPACE="${1:-}"
SELECTED="${2:-}"
CONFIRM="${3:-}"

case "$NAMESPACE" in
  sandbox|default) ;;
  *)
    echo "Usage: $0 sandbox|default namespace:session[,namespace:session...] --yes" >&2
    exit 2
    ;;
esac

if [[ "$CONFIRM" != "--yes" ]]; then
  echo "Refusing to run without explicit --yes confirmation." >&2
  exit 2
fi

if [[ -z "${SELECTED// }" ]]; then
  echo "No sessions selected." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="${TEIWAH_SESSION_CLEANUP_ENV_DIR:-/etc/teiwah/session-cleanup}"
ENV_FILE="${ENV_DIR}/${NAMESPACE}.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing cleanup env file: $ENV_FILE" >&2
  echo "Create it from olivetin/session-cleanup.env.example." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

if [[ "${CLEANUP_NAMESPACE:-}" != "$NAMESPACE" ]]; then
  echo "Refusing to run: $ENV_FILE has CLEANUP_NAMESPACE=${CLEANUP_NAMESPACE:-<unset>}, expected $NAMESPACE" >&2
  exit 1
fi

for required in DATABASE_URL ZUPLO_API_BASE ZUPLO_ACCOUNT ZUPLO_KEY_BUCKET ZUPLO_API_KEY; do
  if [[ -z "${!required:-}" ]]; then
    echo "Missing required env var in $ENV_FILE: $required" >&2
    exit 1
  fi
done

command -v kubectl >/dev/null || {
  echo "kubectl not found" >&2
  exit 1
}
command -v curl >/dev/null || {
  echo "curl not found" >&2
  exit 1
}
command -v psql >/dev/null || {
  echo "psql not found; install postgresql-client on the OliveTin host" >&2
  exit 1
}

SESSION_ID_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

IFS=',' read -r -a TOKENS <<< "$SELECTED"
SESSION_IDS=()
declare -A SEEN=()

for token in "${TOKENS[@]}"; do
  token="${token//[[:space:]]/}"
  [[ -n "$token" ]] || continue

  if [[ "$token" != *:* ]]; then
    echo "Invalid selection value (missing namespace prefix): $token" >&2
    exit 2
  fi

  token_namespace="${token%%:*}"
  session_id="${token#*:}"

  if [[ "$token_namespace" != "$NAMESPACE" ]]; then
    echo "Refusing stale/mismatched selection $token for namespace $NAMESPACE" >&2
    exit 2
  fi

  if [[ ! "$session_id" =~ $SESSION_ID_RE ]]; then
    echo "Invalid session id: $session_id" >&2
    exit 2
  fi

  if [[ -z "${SEEN[$session_id]:-}" ]]; then
    SESSION_IDS+=("$session_id")
    SEEN[$session_id]=1
  fi
done

if [[ "${#SESSION_IDS[@]}" -eq 0 ]]; then
  echo "No valid sessions selected." >&2
  exit 2
fi

echo "FULL HARD DELETE"
echo "Namespace: ${NAMESPACE}"
echo "Env file: ${ENV_FILE}"
echo "Zuplo account: ${ZUPLO_ACCOUNT}"
echo "Zuplo key bucket: ${ZUPLO_KEY_BUCKET}"
echo "Sessions:"
printf '  - %s\n' "${SESSION_IDS[@]}"
echo

delete_zuplo_consumer() {
  local session_id="$1"
  local url="${ZUPLO_API_BASE}/accounts/${ZUPLO_ACCOUNT}/key-buckets/${ZUPLO_KEY_BUCKET}/consumers/${session_id}"
  local body_file
  local status

  body_file="$(mktemp)"
  status="$(
    curl -sS \
      -o "$body_file" \
      -w '%{http_code}' \
      -X DELETE \
      -H "Authorization: Bearer ${ZUPLO_API_KEY}" \
      "$url"
  )"

  case "$status" in
    200|202|204)
      echo "  Zuplo consumer deleted"
      ;;
    404)
      echo "  Zuplo consumer not found; continuing"
      ;;
    *)
      echo "  Zuplo delete failed (${status}): $(cat "$body_file")" >&2
      rm -f "$body_file"
      return 1
      ;;
  esac

  rm -f "$body_file"
}

disconnect_worker_best_effort() {
  local session_id="$1"

  if ! kubectl get deployment "$session_id" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "  Worker deployment not found; skipping disconnect"
    return 0
  fi

  if kubectl exec -n "$NAMESPACE" "deployment/${session_id}" -- \
    sh -c 'if command -v curl >/dev/null 2>&1; then curl -fsS -X POST http://127.0.0.1:${PORT:-8080}/disconnect >/dev/null; elif command -v wget >/dev/null 2>&1; then wget -qO- --method=POST http://127.0.0.1:${PORT:-8080}/disconnect >/dev/null; else exit 127; fi' \
    >/dev/null 2>&1; then
    echo "  Worker disconnect requested"
  else
    echo "  Worker disconnect failed/unavailable; continuing permanent deletion"
  fi
}

delete_k8s_resources() {
  local session_id="$1"

  kubectl delete ingress "$session_id" -n "$NAMESPACE" --ignore-not-found
  kubectl delete middleware "${session_id}-strip" -n "$NAMESPACE" --ignore-not-found
  kubectl delete service "$session_id" -n "$NAMESPACE" --ignore-not-found
  kubectl delete deployment "$session_id" -n "$NAMESPACE" --ignore-not-found
  kubectl delete pvc "$session_id" -n "$NAMESPACE" --ignore-not-found
  kubectl delete pvc "${session_id}-storage" -n "$NAMESPACE" --ignore-not-found
}

hard_delete_db_row() {
  local session_id="$1"
  local deleted_count

  deleted_count="$(
    psql "$DATABASE_URL" \
      -v ON_ERROR_STOP=1 \
      -v session_id="$session_id" \
      -At \
      -c "WITH deleted AS (DELETE FROM sessions WHERE id = :'session_id' RETURNING id) SELECT count(*) FROM deleted;"
  )"

  if [[ "$deleted_count" == "0" ]]; then
    echo "  DB row not found; continuing"
  else
    echo "  DB row hard-deleted"
  fi
}

for session_id in "${SESSION_IDS[@]}"; do
  echo "Deleting ${session_id}..."
  delete_zuplo_consumer "$session_id"
  disconnect_worker_best_effort "$session_id"
  delete_k8s_resources "$session_id"
  hard_delete_db_row "$session_id"
done

echo "Done."
