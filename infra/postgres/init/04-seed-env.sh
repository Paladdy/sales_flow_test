#!/bin/bash
set -euo pipefail

EMPLOYEE_CHAT_ID="${SEED_EMPLOYEE_TELEGRAM_CHAT_ID:-0}"
REGIONAL_CHAT_ID="${SEED_REGIONAL_TELEGRAM_CHAT_ID:-0}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
UPDATE regionals
SET telegram_chat_id = '${REGIONAL_CHAT_ID}'
WHERE regional_id = 'reg_01';

UPDATE employees
SET telegram_chat_id = '${EMPLOYEE_CHAT_ID}'
WHERE employee_id = 'emp_042';
EOSQL

echo "Seed telegram chat IDs applied (employee=${EMPLOYEE_CHAT_ID}, regional=${REGIONAL_CHAT_ID})"
