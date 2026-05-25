# Sales Flow Intelligence

**Post-recording intelligence layer** для розничных продаж: от транскрипции диалога до управленческой аналитики, AI-тренировки и накопления опыта сотрудников.

Запись аудио на точке продаж выполняется upstream-системой и **не входит в scope** данного модуля. Здесь — оркестрация анализа, уведомлений, human-in-the-loop тренировки и отчётности.

---

## Возможности

| Область | Описание |
|---------|----------|
| **Ingest & STT** | Приём события о диалоге, транскрипция, сохранение в PostgreSQL |
| **AI Sales Analyzer** | Structured output: KPI, ошибки, сигналы клиента, рекомендации |
| **Уведомления** | Краткий разбор сотруднику и управленческое предложение регионалу (Telegram) |
| **Training Gate** | Подтверждение тренировки регионалом перед запуском наставника |
| **AI Coach** | Диалог в Telegram: разбор ошибки, ролевая отработка, фиксация результата |
| **Employee Memory** | Структурированная память по повторяющимся ошибкам (`employee_id` + `error_code`) |
| **Kaizen** | Периодические отчёты по частоте ошибок и повторным паттернам |
| **Dashboard** | Read-only витрина метрик поверх PostgreSQL (Metabase) |

---

## Бизнес-поток

| # | Этап | Workflow |
|---|------|----------|
| 1 | Транскрипция и сохранение диалога | WF-01 Ingest |
| 2 | AI-анализ продажи | WF-02 Analyze |
| 3 | Уведомление сотруднику | WF-03 Notify Employee |
| 4 | Предложение тренировки регионалу | WF-04 Notify Regional |
| 5 | Подтверждение тренировки | WF-05 Training Gate |
| 6 | AI-наставник в Telegram | WF-06 Coach |
| 7 | Запись результата в память | WF-07 Memory Write |
| 8 | Kaizen-отчёты (cron) | WF-08 Kaizen |
| 9 | Питание дашборда | WF-09 Dashboard Feed |

---

## Архитектура

```mermaid
flowchart TB
    subgraph upstream [Upstream]
        REC[Audio Recording Service]
    end

    subgraph n8n [n8n Orchestration]
        ING[WF-01 Ingest]
        AN[WF-02 Analyze]
        NE[WF-03 Employee Notify]
        NR[WF-04 Regional Notify]
        TG[WF-05 Training Gate]
        CO[WF-06 Coach]
        MEM[WF-07 Memory Write]
        KZ[WF-08 Kaizen]
        DS[WF-09 Dashboard Feed]
    end

    subgraph external [External Services]
        STT[STT API]
        LLM[LLM API]
        DB[(PostgreSQL)]
        TGAPI[Telegram Bot API]
        DASH[Metabase]
    end

    REC -->|webhook + audio_url| ING
    ING --> STT
    ING --> AN
    AN --> LLM
    AN --> DB
    AN --> NE
    AN --> NR
    NR --> TG
    TG --> CO
    CO --> LLM
    CO --> MEM
    MEM --> DB
    KZ --> DB
    KZ --> DASH
    DS --> DB
    DS --> DASH
    NE --> TGAPI
    NR --> TGAPI
    CO --> TGAPI
```

### Принципы

- **Event-driven** — связь между этапами через PostgreSQL и internal webhooks (`dialog_id`, `session_id`).
- **Idempotency** — повторное событие не создаёт дубль анализа.
- **Single responsibility** — один workflow, одна зона ответственности.
- **Human-in-the-loop** — тренировка запускается только после подтверждения регионалом.
- **Structured AI output** — Analyzer и Coach работают с JSON-схемами, не с произвольным текстом.
- **Observability** — статусы диалога, dead letters, retry на каждом критичном шаге.

### Разделение слоёв

| Слой | Ответственность |
|------|-----------------|
| Ingestion | Валидация, STT, запись транскрипта |
| Analysis | LLM-анализ, KPI и ошибки в `analysis_results` |
| Notification | Форматирование и доставка сообщений |
| Training Gate | Ожидание решения регионала, создание `training_session` |
| Coach | Stateful диалог, outcome сессии |
| Memory & Kaizen | Агрегация ошибок, отчёты, эскалация повторов |
| Dashboard | Read-only представление данных |

---

## Стек

| Компонент | Рекомендация |
|-----------|--------------|
| Оркестрация | n8n (self-hosted) |
| База данных | PostgreSQL (JSONB, views, structured memory) |
| STT | OpenAI Whisper / Yandex SpeechKit |
| LLM | GPT-4o / Claude (structured output + coach) |
| Telegram | Bot API (inline-кнопки, диалог наставника) |
| Дашборд | Metabase |
| LLM (dev) | Ollama — опционально для локальной разработки |

---

## Структура репозитория

```
sales_flow_test/
├── infra/                  # Docker Compose, PostgreSQL init, Makefile
│   ├── docker-compose.yml
│   ├── postgres/init/      # Схема БД и seed
│   └── .env.example
├── scripts/
│   ├── demo.sh             # Локальная оркестрация webhook-цепочки
│   └── ensure-telegram.sh
└── workflows/              # Экспорт n8n (не коммитится по умолчанию)
```

Реализация бизнес-логики — **n8n workflows** (9 WF), собираемые поверх схемы PostgreSQL и контрактов webhook.

---

## Быстрый старт

### 1. Инфраструктура

```bash
cd infra
cp .env.example .env   # пароли, WEBHOOK_URL, Telegram
make up
```

Сервисы:

| Сервис | URL |
|--------|-----|
| n8n | http://localhost:5678 |
| PostgreSQL | `localhost:5432`, БД `sales_flow` |
| Metabase (optional) | `make dashboard` → http://localhost:3000 |
| Ollama (optional) | http://localhost:11434 |

Схема БД применяется автоматически из `infra/postgres/init/`.

### 2. Конфигурация

В `infra/.env` задайте:

- `POSTGRES_PASSWORD`, `N8N_BASIC_AUTH_*`, `N8N_ENCRYPTION_KEY`
- `WEBHOOK_URL` — публичный HTTPS URL для Telegram webhooks (tunnel в dev)
- `TELEGRAM_BOT_TOKEN`, `N8N_TG_WEBHOOK_ID`, `N8N_TG_WEBHOOK_SECRET`
- `SEED_*_TELEGRAM_CHAT_ID` — chat ID для seed-данных

Credentials для STT/LLM настраиваются в n8n.

### 3. n8n workflows

1. Импортировать или собрать WF-01 … WF-09 в n8n.
2. Привязать PostgreSQL и Telegram credentials.
3. Настроить Error Workflow (dead letters + алерт).
4. Активировать workflows и проверить цепочку ingest → analyze → notify → coach → memory.

### 4. Операции

```bash
make ps          # статус контейнеров
make logs        # логи
make shell-db    # psql в sales_flow
make restart     # перезапуск + перерегистрация Telegram webhook
make down        # остановка
```

---

## Модель данных (ключевые сущности)

| Таблица | Назначение |
|---------|------------|
| `dialogs` | Диалог, статус pipeline (`ingested` → `coaching_done`) |
| `analysis_results` | JSON-результат Analyzer |
| `pending_training_actions` | Токен inline-кнопки для регионала |
| `training_sessions` | Состояние сессии Coach (`intro`, `roleplay`, `done`) |
| `employee_memory` | Память по ошибкам: `occurrence_count`, `coaching_notes` |
| `kaizen_reports` | Сгенерированные отчёты |
| `dead_letters` | Ошибки pipeline для разбора |

---

## Безопасность и compliance

- Секреты — только в `.env` и n8n Credentials; `.env` не коммитится.
- Обработка аудио и персональных данных требует согласования с юристами (152-ФЗ, уведомление о записи, retention).
- Рекомендуется политика хранения для транскриптов, памяти сотрудников и логов.
- Internal webhooks — защита через secret token и Basic Auth на n8n UI.

---

## Эволюция в production

| Слой | Текущая реализация | Production |
|------|-------------------|------------|
| Оркестрация | n8n | FastAPI + Celery/ARQ |
| Контракты БД | PostgreSQL, JSON schema | Без изменений |
| LLM / Telegram | n8n nodes | Python-сервисы |
| RAG (скрипт продаж, KB) | Roadmap | pgvector + корпоративные документы |

n8n используется как **integration layer на этапе внедрения**; целевая industrial-архитектура — Python-сервисы поверх той же схемы данных.

---

## Лицензия и статус

Проект находится в стадии **пилотной интеграции**. Production rollout требует hardening STT, diarization, корпоративного rubric и юридического согласования.
