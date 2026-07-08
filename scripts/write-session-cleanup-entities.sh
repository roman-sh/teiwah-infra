#!/usr/bin/env bash
set -euo pipefail

# Generate the OliveTin checklist entity file for selected session cleanup.
#
# The generated checkbox values include the namespace (`namespace:sessionId`) so
# a stale sandbox/default list cannot be submitted against the wrong namespace.
#
# Env files are intentionally outside the repo because they contain DB/Zuplo
# secrets:
#   /etc/teiwah/session-cleanup/sandbox.env
#   /etc/teiwah/session-cleanup/default.env

NAMESPACE="${1:-}"

case "$NAMESPACE" in
  sandbox|default) ;;
  *)
    echo "Usage: $0 sandbox|default" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENTITY_DIR="${REPO_ROOT}/olivetin/entities"
ENTITY_FILE="${ENTITY_DIR}/cleanup-sessions.jsonl"
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

command -v kubectl >/dev/null || {
  echo "kubectl not found" >&2
  exit 1
}
command -v psql >/dev/null || {
  echo "psql not found; install postgresql-client on the OliveTin host" >&2
  exit 1
}

SESSION_ID_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

declare -A SOURCES_BY_ID=()

add_source() {
  local session_id="$1"
  local source="$2"

  [[ "$session_id" =~ $SESSION_ID_RE ]] || return 0

  if [[ -n "${SOURCES_BY_ID[$session_id]:-}" ]]; then
    SOURCES_BY_ID[$session_id]="${SOURCES_BY_ID[$session_id]},${source}"
  else
    SOURCES_BY_ID[$session_id]="$source"
  fi
}

while IFS= read -r deployment; do
  [[ -n "$deployment" ]] && add_source "$deployment" "deployment"
done < <(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

while IFS= read -r pvc; do
  [[ -n "$pvc" ]] || continue
  add_source "$pvc" "pvc"
  if [[ "$pvc" == *-storage ]]; then
    add_source "${pvc%-storage}" "legacy-pvc"
  fi
done < <(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

while IFS=$'\t' read -r session_id db_state; do
  [[ -n "$session_id" ]] && add_source "$session_id" "$db_state"
done < <(
  psql "$DATABASE_URL" \
    -v ON_ERROR_STOP=1 \
    -At \
    -F $'\t' \
    -c "SELECT id, CASE WHEN \"isDeleted\" THEN 'db-deleted' ELSE 'db-active' END FROM sessions ORDER BY \"createdAt\" DESC;"
)

mkdir -p "$ENTITY_DIR"
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

for session_id in "${!SOURCES_BY_ID[@]}"; do
  sources="${SOURCES_BY_ID[$session_id]}"
  title="${NAMESPACE} / ${session_id} — ${sources}"
  printf '{"Namespace":"%s","Name":"%s","Value":"%s:%s","Title":"%s"}\n' \
    "$NAMESPACE" \
    "$session_id" \
    "$NAMESPACE" \
    "$session_id" \
    "$title"
done | sort > "$tmp_file"

mv "$tmp_file" "$ENTITY_FILE"
trap - EXIT

count="$(wc -l < "$ENTITY_FILE" | tr -d ' ')"
echo "Wrote ${count} cleanup session choices for namespace ${NAMESPACE}: ${ENTITY_FILE}"
