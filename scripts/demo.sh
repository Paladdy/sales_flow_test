#!/usr/bin/env bash
# Демо Sales Flow — одна команда, без psql_sf и jq.
# Использование: ./scripts/demo.sh help

set -euo pipefail

N8N="http://localhost:5678"
DIALOG="770e8400-e29b-41d4-a716-446655440002"
EMP="emp_042"
STORE="store_001"

if [[ -f "$(dirname "$0")/../infra/.env" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/../infra/.env"
fi
# WF-06 Telegram Trigger — задай в infra/.env (не коммитить)
TG_WEBHOOK_ID="${N8N_TG_WEBHOOK_ID:-}"
TG_SECRET="${N8N_TG_WEBHOOK_SECRET:-}"
TG_BOT="${TELEGRAM_BOT_TOKEN:-}"
WEBHOOK_URL="${WEBHOOK_URL:-http://localhost:5678/}"
WEBHOOK_URL="${WEBHOOK_URL%/}/"

ensure_telegram() {
  if [[ -z "${TG_BOT}" || -z "${TG_WEBHOOK_ID}" || -z "${TG_SECRET}" ]]; then
    echo "!!! Задай TELEGRAM_BOT_TOKEN, N8N_TG_WEBHOOK_ID, N8N_TG_WEBHOOK_SECRET в infra/.env"
    return 1
  fi
  echo "=== Telegram webhook: message + callback_query ==="
  local resp ok
  resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT}/setWebhook" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"${WEBHOOK_URL}webhook/${TG_WEBHOOK_ID}/webhook\",\"allowed_updates\":[\"message\",\"callback_query\"],\"secret_token\":\"${TG_SECRET}\",\"drop_pending_updates\":false}")
  ok=$(echo "${resp}" | grep -c '"ok":true' || true)
  if [[ "${ok}" -ge 1 ]]; then
    echo "OK"
  else
    echo "!!! setWebhook failed: ${resp}"
    echo "    Проверь: ngrok запущен, WEBHOOK_URL в infra/.env"
    return 1
  fi
}

# После рестарта n8n перезаписывает webhook — вызывать ensure после up/restart
wait_n8n() {
  local i
  for i in $(seq 1 30); do
    curl -sf "${N8N}/healthz" >/dev/null 2>&1 && return 0
    curl -sf "${N8N}/" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "!!! n8n не отвечает на ${N8N}"
  return 1
}

post_n8n_start() {
  wait_n8n
  # WF-05 inactive, но n8n может оставить старый TG webhook — убираем
  pg_n8n() { docker exec sales-flow-postgres psql -U salesflow -d n8n -c "$1"; }
  pg_n8n "DELETE FROM webhook_entity WHERE \"workflowId\" = 'SRzWwdEzXlziXTrf';" >/dev/null || true
  ensure_telegram
}

pg() {
  docker exec sales-flow-postgres psql -U salesflow -d sales_flow -c "$1"
}

reset() {
  echo "=== RESET ==="
  pg "
DELETE FROM employee_memory WHERE employee_id = '${EMP}';
DELETE FROM kaizen_reports WHERE store_id = '${STORE}';
DELETE FROM training_sessions WHERE dialog_id = '${DIALOG}'::uuid;
DELETE FROM pending_training_actions WHERE dialog_id = '${DIALOG}'::uuid;
DELETE FROM notifications WHERE dialog_id = '${DIALOG}'::uuid;
DELETE FROM analysis_results WHERE dialog_id = '${DIALOG}'::uuid;
DELETE FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;
REFRESH MATERIALIZED VIEW v_dashboard_summary;
"
  pg "SELECT dialog_id, status FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;"
}

wf01() {
  echo "=== WF-01 ingest ==="
  EXISTING=$(docker exec sales-flow-postgres psql -U salesflow -d sales_flow -t -A -c \
    "SELECT status FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;" 2>/dev/null || true)
  if [[ -n "${EXISTING}" ]]; then
    echo "!!! Диалог уже есть (status=${EXISTING}). Сначала: ./scripts/demo.sh reset"
    echo
  fi
  RESP=$(curl -s -X POST "${N8N}/webhook/dialog-ingest" \
    -H "Content-Type: application/json" \
    -d "{\"dialog_id\":\"${DIALOG}\",\"store_id\":\"${STORE}\",\"employee_id\":\"${EMP}\",\"recorded_at\":\"2026-05-22T14:30:00+03:00\",\"audio_url\":\"https://example.com/demo.wav\",\"duration_sec\":87}")
  echo "${RESP}"
  if echo "${RESP}" | grep -q "Error in workflow"; then
    echo ">>> Ошибка n8n — почти всегда диалог уже в базе. Запусти: ./scripts/demo.sh reset && ./scripts/demo.sh wf01"
  fi
  # WF-01 Insert иногда пишет employee_id с хвостовым \\n — без trim WF-03/04 не находят сотрудника
  pg "UPDATE dialogs SET employee_id = trim(both E'\\n\\r ' from employee_id), store_id = trim(both E'\\n\\r ' from store_id) WHERE dialog_id = '${DIALOG}'::uuid;"
  echo
  pg "SELECT dialog_id, status, left(transcript, 80) FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;"
}

wf02() {
  echo "=== WF-02 analyze ==="
  curl -s -X POST "${N8N}/webhook/analyze" \
    -H "Content-Type: application/json" \
    -d "{\"dialog_id\":\"${DIALOG}\"}"
  echo
  pg "SELECT d.status, ar.result->'errors'->0->>'code' AS error, ar.result->'kpi'->>'overall_score' AS score
      FROM dialogs d JOIN analysis_results ar ON ar.dialog_id = d.dialog_id
      WHERE d.dialog_id = '${DIALOG}'::uuid;"
}

wf03() {
  echo "=== WF-03 notify employee ==="
  curl -s -X POST "${N8N}/webhook/notify-employee" \
    -H "Content-Type: application/json" \
    -d "{\"dialog_id\":\"${DIALOG}\"}"
  echo
  pg "SELECT status FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;"
}

wf04() {
  echo "=== WF-04 notify regional ==="
  curl -s -X POST "${N8N}/webhook/notify-regional" \
    -H "Content-Type: application/json" \
    -d "{\"dialog_id\":\"${DIALOG}\"}"
  echo
  pg "SELECT status FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;"
}

wf05() {
  echo "=== WF-05 approve training (curl — для auto demo или если кнопка не сработала) ==="
  TOKEN=$(docker exec sales-flow-postgres psql -U salesflow -d sales_flow -t -A -c \
    "SELECT action_token FROM pending_training_actions WHERE dialog_id = '${DIALOG}'::uuid AND used_at IS NULL ORDER BY created_at DESC LIMIT 1;")
  if [[ -z "${TOKEN}" ]]; then
    echo "!!! Нет pending_training_actions — сначала ./scripts/demo.sh wf04"
    exit 1
  fi
  pg "
UPDATE pending_training_actions SET used_at = NOW() WHERE action_token = '${TOKEN}'::uuid;
UPDATE dialogs SET status = 'training_approved', updated_at = NOW()
  WHERE dialog_id = '${DIALOG}'::uuid AND status = 'awaiting_training_confirm';
"
  curl -s -X POST "${N8N}/webhook/start-coach" \
    -H "Content-Type: application/json" \
    -d "{\"dialog_id\":\"${DIALOG}\",\"employee_id\":\"${EMP}\"}"
  echo
  echo ">>> Ждём старт coach (5 сек)..."
  sleep 5
  pg "SELECT status FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;
      SELECT session_id, state FROM training_sessions WHERE dialog_id = '${DIALOG}'::uuid ORDER BY started_at DESC LIMIT 1;"
  echo ">>> Дальше в Telegram: ответить боту 2–4 раза (WF-06), или ./scripts/demo.sh wf06-finish"
}

wf06() {
  echo "=== WF-06 start coach (если уже training_approved) ==="
  curl -s -X POST "${N8N}/webhook/start-coach" \
    -H "Content-Type: application/json" \
    -d "{\"dialog_id\":\"${DIALOG}\",\"employee_id\":\"${EMP}\"}"
  echo
  pg "SELECT status FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;
      SELECT session_id, state FROM training_sessions WHERE dialog_id = '${DIALOG}'::uuid ORDER BY started_at DESC LIMIT 1;"
  echo ">>> Дальше в Telegram: ответить боту 2–4 раза"
}

wf06_finish() {
  echo "=== WF-06 finish (если Telegram не отвечает) ==="
  CHAT_ID=$(docker exec sales-flow-postgres psql -U salesflow -d sales_flow -t -A -c \
    "SELECT telegram_chat_id FROM employees WHERE employee_id = '${EMP}';")
  SESSION_ID=$(docker exec sales-flow-postgres psql -U salesflow -d sales_flow -t -A -c \
    "SELECT session_id FROM training_sessions WHERE dialog_id = '${DIALOG}'::uuid AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1;")
  if [[ -z "${SESSION_ID}" ]]; then
    echo "!!! Нет активной сессии — сначала ./scripts/demo.sh wf05"
    exit 1
  fi
  MSG='Отлично! Вы задали вопросы и предложили варианты — так и нужно. Совет: начинайте с «Для кого выбираете?» и «Что важнее — нежирное или вкус?». Тренировка завершена!'
  pg "
UPDATE training_sessions SET
  state = 'done',
  ended_at = NOW(),
  context = context
    || jsonb_build_object('role','user','text','Докторскую, нарежьте пожалуйста','at', NOW()::text)
    || jsonb_build_object('role','assistant','text','${MSG}','at', NOW()::text)
WHERE session_id = '${SESSION_ID}'::uuid;
UPDATE dialogs SET status = 'coaching', updated_at = NOW() WHERE dialog_id = '${DIALOG}'::uuid;
"
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":${CHAT_ID},\"text\":\"${MSG}\"}"
  echo
  echo ">>> Сессия завершена. Дальше: ./scripts/demo.sh wf07"
  pg "SELECT session_id, state, ended_at IS NOT NULL AS done FROM training_sessions WHERE session_id = '${SESSION_ID}'::uuid;"
}

wf07() {
  echo "=== WF-07 write memory ==="
  SESSION_ID=$(docker exec sales-flow-postgres psql -U salesflow -d sales_flow -t -A -c \
    "SELECT session_id FROM training_sessions WHERE dialog_id = '${DIALOG}'::uuid ORDER BY started_at DESC LIMIT 1;")
  if [[ -z "${SESSION_ID}" ]]; then
    echo "!!! Нет training_sessions — сначала ./scripts/demo.sh wf05 && wf06-finish"
    exit 1
  fi
  curl -s -X POST "${N8N}/webhook/write-memory" \
    -H "Content-Type: application/json" \
    -d "{\"session_id\":\"${SESSION_ID}\",\"dialog_id\":\"${DIALOG}\"}"
  echo
  pg "SELECT * FROM employee_memory WHERE employee_id = '${EMP}';"
}

status() {
  pg "SELECT dialog_id, status FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;"
}

curl-all() {
  wf01
  wf02
  wf03
  wf04
}

manual() {
  ensure_telegram
  reset
  curl-all
  ensure_telegram
  cat <<'EOF'

=== MANUAL DEMO — дальше вручную (для видео) ===

  WF-05: в Telegram нажать «✅ Подтвердить тренировку»
         → coach стартует сам, придёт первое сообщение
  WF-06: ответить боту 2–4 раза (ролевая игра)
  WF-07: ./scripts/demo.sh wf07

  Проверить статус: ./scripts/demo.sh status

  Запасной план (только если TG сломался):
    ./scripts/demo.sh wf05 && ./scripts/demo.sh wf06-finish && ./scripts/demo.sh wf07
EOF
}

auto() {
  ensure_telegram
  reset
  curl-all
  wf05
  wf06_finish
  sleep 3
  wf07
  echo ">>> Ждём WF-07 (8 сек)..."
  sleep 8
  echo "=== AUTO DEMO DONE ==="
  pg "SELECT dialog_id, status FROM dialogs WHERE dialog_id = '${DIALOG}'::uuid;"
  pg "SELECT employee_id, error_code, occurrence_count FROM employee_memory WHERE employee_id = '${EMP}';"
}

# alias
full() { auto; }

help() {
  cat <<EOF
Sales Flow demo — без export и psql_sf.

Два режима прогона:

  ./scripts/demo.sh manual   — WF-01→04, дальше кнопка в TG + переписка + wf07
  ./scripts/demo.sh auto     — WF-01→07 автоматически (curl вместо кнопки)
  ./scripts/demo.sh ensure-telegram — починить webhook (после restart n8n)
  ./scripts/demo.sh post-n8n     — подождать n8n + ensure-telegram
  ./scripts/demo.sh full     — то же что auto

Отдельные шаги:

  ./scripts/demo.sh reset      — очистить тестовый диалог
  ./scripts/demo.sh curl-all   — WF-01 → 02 → 03 → 04
  ./scripts/demo.sh wf05       — подтвердить тренировку curl (auto / запасной)
  ./scripts/demo.sh wf06-finish — завершить тренировку curl (если TG молчит)
  ./scripts/demo.sh wf07       — записать память
  ./scripts/demo.sh status     — текущий статус

Manual (для записи видео):
  ./scripts/demo.sh manual
  → Telegram: «Подтвердить тренировку»
  → Telegram: 2–4 ответа боту
  → ./scripts/demo.sh wf07

Auto (быстрая проверка стенда):
  ./scripts/demo.sh auto

  WF-08/09: Execute в n8n UI
EOF
}

cmd="${1:-help}"
case "$cmd" in
  reset) reset ;;
  ensure-telegram|tg) ensure_telegram ;;
  post-n8n) post_n8n_start ;;
  manual|demo-manual) manual ;;
  auto|demo-auto) auto ;;
  full) full ;;
  wf01|01) wf01 ;;
  wf02|02) wf02 ;;
  wf03|03) wf03 ;;
  wf04|04) wf04 ;;
  wf05|05) wf05 ;;
  wf06-finish|06-finish|finish) wf06_finish ;;
  wf06|06) wf06 ;;
  wf07|07) wf07 ;;
  curl-all|curl) curl-all ;;
  status|st) status ;;
  help|-h|--help) help ;;
  *) echo "Неизвестно: $cmd"; help; exit 1 ;;
esac
