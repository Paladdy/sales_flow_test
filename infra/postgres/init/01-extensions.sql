-- Extensions for app DB (sales_flow)
-- pgvector — reserved for future RAG (see docs/RAG_ROADMAP.md)

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";

COMMENT ON EXTENSION vector IS 'TODO: RAG knowledge base — not used in MVP';
