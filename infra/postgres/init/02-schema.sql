-- Sales Flow application schema
-- Spec: docs/CONTRACTS.md

CREATE TABLE IF NOT EXISTS dialogs (
  dialog_id UUID PRIMARY KEY,
  store_id TEXT NOT NULL,
  employee_id TEXT NOT NULL,
  audio_url TEXT,
  recorded_at TIMESTAMPTZ,
  duration_sec INT,
  raw_transcript TEXT,
  transcript TEXT,
  status TEXT NOT NULL DEFAULT 'received',
  retry_count INT DEFAULT 0,
  received_at TIMESTAMPTZ DEFAULT NOW(),
  transcribed_at TIMESTAMPTZ,
  analyzed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dialogs_status ON dialogs(status);
CREATE INDEX IF NOT EXISTS idx_dialogs_store_recorded ON dialogs(store_id, recorded_at);

CREATE TABLE IF NOT EXISTS analysis_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dialog_id UUID UNIQUE REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
  result JSONB NOT NULL,
  model_version TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS regionals (
  regional_id TEXT PRIMARY KEY,
  full_name TEXT,
  telegram_chat_id TEXT
);

CREATE TABLE IF NOT EXISTS employees (
  employee_id TEXT PRIMARY KEY,
  store_id TEXT NOT NULL,
  full_name TEXT,
  telegram_chat_id TEXT,
  regional_id TEXT REFERENCES regionals(regional_id),
  is_active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dialog_id UUID REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
  recipient_type TEXT NOT NULL CHECK (recipient_type IN ('employee', 'regional', 'ops')),
  telegram_message_id TEXT,
  sent_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (dialog_id, recipient_type)
);

CREATE TABLE IF NOT EXISTS pending_training_actions (
  action_token UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dialog_id UUID REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ DEFAULT NOW() + INTERVAL '72 hours',
  used_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_pending_training_dialog
  ON pending_training_actions(dialog_id)
  WHERE used_at IS NULL;

CREATE TABLE IF NOT EXISTS training_sessions (
  session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dialog_id UUID REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
  employee_id TEXT REFERENCES employees(employee_id),
  state TEXT NOT NULL DEFAULT 'intro'
    CHECK (state IN ('intro', 'roleplay', 'feedback', 'done')),
  context JSONB DEFAULT '[]'::jsonb,
  started_at TIMESTAMPTZ DEFAULT NOW(),
  ended_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_training_sessions_active
  ON training_sessions(employee_id, started_at DESC)
  WHERE ended_at IS NULL;

CREATE TABLE IF NOT EXISTS employee_memory (
  employee_id TEXT REFERENCES employees(employee_id) ON DELETE CASCADE,
  error_code TEXT NOT NULL,
  occurrence_count INT DEFAULT 1,
  last_seen_at TIMESTAMPTZ DEFAULT NOW(),
  last_training_at TIMESTAMPTZ,
  coaching_notes TEXT,
  PRIMARY KEY (employee_id, error_code)
);

CREATE TABLE IF NOT EXISTS dead_letters (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dialog_id UUID,
  step TEXT NOT NULL,
  error_code TEXT,
  error_message TEXT,
  payload JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dead_letters_created ON dead_letters(created_at DESC);

CREATE TABLE IF NOT EXISTS kaizen_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id TEXT,
  report_type TEXT CHECK (report_type IN ('daily', 'weekly')),
  report_date DATE,
  content TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Optional queue table for manual retry / observability
CREATE TABLE IF NOT EXISTS job_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dialog_id UUID REFERENCES dialogs(dialog_id) ON DELETE CASCADE,
  step TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'done', 'failed')),
  retry_count INT DEFAULT 0,
  max_retries INT DEFAULT 3,
  next_run_at TIMESTAMPTZ DEFAULT NOW(),
  last_error TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_job_queue_pending
  ON job_queue(status, next_run_at)
  WHERE status IN ('pending', 'failed');

-- Views
CREATE OR REPLACE VIEW v_error_frequency AS
SELECT
  d.store_id,
  d.employee_id,
  err->>'code' AS error_code,
  COUNT(*) AS cnt,
  DATE(d.analyzed_at) AS day
FROM dialogs d
JOIN analysis_results ar ON ar.dialog_id = d.dialog_id
CROSS JOIN LATERAL jsonb_array_elements(ar.result->'errors') AS err
WHERE d.analyzed_at IS NOT NULL
GROUP BY d.store_id, d.employee_id, err->>'code', DATE(d.analyzed_at);

CREATE MATERIALIZED VIEW IF NOT EXISTS v_dashboard_summary AS
SELECT
  d.store_id,
  DATE(d.received_at) AS day,
  COUNT(*) AS dialogs_total,
  COUNT(*) FILTER (WHERE d.status = 'coaching_done') AS trainings_done,
  AVG((ar.result->'kpi'->>'overall_score')::float) AS avg_score
FROM dialogs d
LEFT JOIN analysis_results ar ON ar.dialog_id = d.dialog_id
GROUP BY d.store_id, DATE(d.received_at);

CREATE UNIQUE INDEX IF NOT EXISTS idx_v_dashboard_summary
  ON v_dashboard_summary(store_id, day);

-- TODO: RAG tables (production) — see docs/RAG_ROADMAP.md
-- knowledge_documents, knowledge_chunks (embedding vector(1536)), ...
