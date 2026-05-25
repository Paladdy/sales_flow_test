#!/usr/bin/env bash
# Перерегистрация Telegram webhook после рестарта n8n.
# Вызывается из demo.sh manual/auto и make ensure-telegram.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${DIR}/demo.sh" ensure-telegram
