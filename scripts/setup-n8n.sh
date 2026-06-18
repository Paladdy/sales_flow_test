#!/usr/bin/env bash
# Import n8n workflows from workflows/export/ + ensure Postgres/Telegram credentials.
# Uses docker exec + psql (no N8N API key required).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFRA="$ROOT/infra"
EXPORT_DIR="$ROOT/workflows/export"
N8N_CONTAINER="${N8N_CONTAINER:-sales-flow-n8n}"
PG_CONTAINER="${PG_CONTAINER:-sales-flow-postgres}"

if [[ ! -f "$INFRA/.env" ]]; then
  echo "!!! Сначала: cd infra && cp .env.example .env"
  exit 1
fi
# shellcheck disable=SC1091
source "$INFRA/.env"

N8N_PORT="${N8N_PORT:-5678}"
N8N_URL="http://localhost:${N8N_PORT}"

pg_n8n() {
  docker exec "${PG_CONTAINER}" psql -U "${POSTGRES_USER}" -d n8n -t -A -c "$1"
}

wait_n8n() {
  local i
  for i in $(seq 1 45); do
    if curl -sf "${N8N_URL}/healthz" >/dev/null 2>&1 || curl -sf "${N8N_URL}/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "!!! n8n не отвечает на ${N8N_URL}. Запустите: cd infra && make up"
  exit 1
}

find_cred_id() {
  local name="$1"
  pg_n8n "SELECT id FROM credentials_entity WHERE name = '${name}' LIMIT 1;"
}

ensure_postgres_cred() {
  local id name
  for name in "Sales Flow Postgres" "Postgres account"; do
    id="$(find_cred_id "${name}" || true)"
    if [[ -n "${id}" ]]; then
      echo "PostgreSQL credential: ${name} (${id})" >&2
      echo "${id}"
      return 0
    fi
  done

  local tmp
  tmp="$(mktemp)"
  python3 <<PY > "${tmp}"
import json
print(json.dumps([{
  "name": "Sales Flow Postgres",
  "type": "postgres",
  "data": {
    "host": "postgres",
    "port": 5432,
    "database": "${POSTGRES_DB}",
    "user": "${POSTGRES_USER}",
    "password": "${POSTGRES_PASSWORD}",
    "ssl": "disable"
  }
}]))
PY
  docker cp "${tmp}" "${N8N_CONTAINER}:/tmp/postgres-cred.json"
  rm -f "${tmp}"
  docker exec "${N8N_CONTAINER}" n8n import:credentials --input=/tmp/postgres-cred.json >/dev/null
  id="$(find_cred_id "Sales Flow Postgres")"
  echo "Created PostgreSQL credential: ${id}" >&2
  echo "${id}"
}

ensure_telegram_cred() {
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    echo "!!! TELEGRAM_BOT_TOKEN не задан в infra/.env" >&2
    exit 1
  fi

  local id name
  for name in "Telegram Bot" "Telegram account"; do
    id="$(find_cred_id "${name}" || true)"
    if [[ -n "${id}" ]]; then
      echo "Telegram credential: ${name} (${id})" >&2
      echo "${id}"
      return 0
    fi
  done

  local tmp
  tmp="$(mktemp)"
  python3 <<PY > "${tmp}"
import json
print(json.dumps([{
  "name": "Telegram Bot",
  "type": "telegramApi",
  "data": {
    "accessToken": "${TELEGRAM_BOT_TOKEN}"
  }
}]))
PY
  docker cp "${tmp}" "${N8N_CONTAINER}:/tmp/telegram-cred.json"
  rm -f "${tmp}"
  docker exec "${N8N_CONTAINER}" n8n import:credentials --input=/tmp/telegram-cred.json >/dev/null
  id="$(find_cred_id "Telegram Bot")"
  echo "Created Telegram credential: ${id}" >&2
  echo "${id}"
}

remove_existing_workflows() {
  local names
  names="$(python3 - <<PY
import json
from pathlib import Path
root = Path("${EXPORT_DIR}")
for path in sorted(root.glob("WF-*.json")):
    print(json.loads(path.read_text(encoding="utf-8"))["name"])
PY
)"
  local name ids
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    ids="$(pg_n8n "SELECT id FROM workflow_entity WHERE name = '${name//\'/''}';" || true)"
    if [[ -n "${ids}" ]]; then
      while IFS= read -r wf_id; do
        [[ -z "${wf_id}" ]] && continue
        pg_n8n "DELETE FROM workflow_entity WHERE id = '${wf_id}';" >/dev/null
        echo "Removed old workflow: ${name} (${wf_id})" >&2
      done <<< "${ids}"
    fi
  done <<< "${names}"
}

import_workflows() {
  local pg_id="$1"
  local tg_id="$2"
  local staging
  staging="$(mktemp -d)"

  shopt -s nullglob
  for file in "${EXPORT_DIR}"/WF-*.json; do
    sed -e "s/__POSTGRES_CRED_ID__/${pg_id}/g" \
        -e "s/__TELEGRAM_CRED_ID__/${tg_id}/g" \
        "${file}" > "${staging}/$(basename "${file}")"
  done

  docker exec "${N8N_CONTAINER}" mkdir -p /home/node/.n8n/import-batch
  docker cp "${staging}/." "${N8N_CONTAINER}:/home/node/.n8n/import-batch/"
  rm -rf "${staging}"

  docker exec "${N8N_CONTAINER}" n8n import:workflow \
    --separate --input=/home/node/.n8n/import-batch
}

activate_workflows() {
  local ids name
  while IFS='|' read -r id name; do
    [[ -z "${id}" ]] && continue
    if [[ "${name}" == "WF-05 Training Gate" ]]; then
      echo "Skip activate (manual/TG): ${name}" >&2
      continue
    fi
    docker exec "${N8N_CONTAINER}" n8n publish:workflow --id="${id}" >/dev/null 2>&1 \
      || docker exec "${N8N_CONTAINER}" n8n update:workflow --id="${id}" --active=true >/dev/null 2>&1 \
      || true
    echo "Activated: ${name}" >&2
  done <<< "$(pg_n8n "SELECT id, name FROM workflow_entity WHERE name LIKE 'WF-%' ORDER BY name;")"
}

main() {
  if [[ ! -d "${EXPORT_DIR}" ]] || [[ -z "$(ls -A "${EXPORT_DIR}"/*.json 2>/dev/null || true)" ]]; then
    echo "!!! Нет workflows/export/*.json"
    echo "    python3 scripts/sanitize-workflows.py"
    exit 1
  fi

  echo "=== Waiting for n8n ==="
  wait_n8n

  echo "=== Credentials ==="
  PG_ID="$(ensure_postgres_cred)"
  TG_ID="$(ensure_telegram_cred)"

  echo "=== Replace existing workflows ==="
  remove_existing_workflows

  echo "=== Import workflows ==="
  import_workflows "${PG_ID}" "${TG_ID}"

  echo "=== Activate workflows ==="
  activate_workflows

  echo "=== Restart n8n (refresh webhook registry) ==="
  docker restart "${N8N_CONTAINER}" >/dev/null
  wait_n8n

  cat <<EOF

=== Workflows ready ===
n8n UI: ${N8N_URL}

Auto demo:
  cd infra && make demo-auto

Manual demo (ngrok + webhook):
  cd infra && make demo-manual
EOF
}

main "$@"
