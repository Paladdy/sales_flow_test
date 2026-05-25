#!/bin/bash
# Self-signed TLS for local Postgres (dev only).
# Certs live OUTSIDE PGDATA so initdb still sees an empty data directory.
set -euo pipefail

SSL_DIR="/var/lib/postgresql/ssl"
SSL_CERT="${SSL_DIR}/server.crt"
SSL_KEY="${SSL_DIR}/server.key"

mkdir -p "$SSL_DIR"

if [ ! -f "$SSL_KEY" ]; then
  echo "Generating self-signed Postgres SSL certificate..."
  openssl req -new -x509 -days 3650 -nodes \
    -out "$SSL_CERT" \
    -keyout "$SSL_KEY" \
    -subj "/CN=postgres"
  chmod 600 "$SSL_KEY"
  chown postgres:postgres "$SSL_KEY" "$SSL_CERT"
fi

exec docker-entrypoint.sh postgres \
  -c ssl=on \
  -c ssl_cert_file="$SSL_CERT" \
  -c ssl_key_file="$SSL_KEY"
