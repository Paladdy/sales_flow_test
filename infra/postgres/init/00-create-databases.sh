#!/bin/bash
set -euo pipefail

# Creates auxiliary databases for n8n and Metabase (optional profile).
# Main app schema lives in POSTGRES_DB (sales_flow).

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
SELECT 'CREATE DATABASE n8n'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'n8n')\gexec

SELECT 'CREATE DATABASE metabase'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'metabase')\gexec
EOSQL

echo "Auxiliary databases ensured: n8n, metabase"
