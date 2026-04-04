#!/usr/bin/env bash
set -e

echo "============================================="
echo "  Companion Platform - Single Container"
echo "============================================="
echo ""

# ── Initialize PostgreSQL ─────────────────────────────────────────────────────
if [ ! -f /var/lib/postgresql/data/PG_VERSION ]; then
    echo "[init] Initializing PostgreSQL..."
    pg_dropcluster 15 main 2>/dev/null || true
    pg_createcluster 15 main -- --auth-local=trust --auth-host=md5
fi

# Configure PostgreSQL to listen on all interfaces and allow connections
cat > /etc/postgresql/15/main/conf.d/companion.conf << 'PGEOF'
listen_addresses = '*'
port = 5432
max_connections = 100
shared_buffers = 128MB
PGEOF

# Set up pg_hba.conf to allow password auth
cat > /etc/postgresql/15/main/pg_hba.conf << 'PGEOF'
local   all   all                 trust
host    all   all   127.0.0.1/32  md5
host    all   all   ::1/128       md5
host    all   all   0.0.0.0/0     md5
PGEOF

# Start PostgreSQL temporarily for init
echo "[init] Starting PostgreSQL for initialization..."
pg_ctlcluster 15 main start

# Wait for PostgreSQL to be ready
for i in $(seq 1 30); do
    if pg_isready -h /var/run/postgresql -U postgres > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Create roles and schemas (use local socket for trust auth)
psql -h /var/run/postgresql -U postgres -d postgres << 'SQLEOF'
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'supabase_admin') THEN
        CREATE ROLE supabase_admin SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD 'postgres';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
        CREATE ROLE anon;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'service_role') THEN
        CREATE ROLE service_role;
    END IF;
END
$$;

CREATE SCHEMA IF NOT EXISTS hivemind;
CREATE SCHEMA IF NOT EXISTS vexa;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS _realtime;

GRANT ALL ON SCHEMA hivemind TO supabase_admin, anon, authenticated, service_role;
GRANT ALL ON SCHEMA vexa TO supabase_admin, anon, authenticated, service_role;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQLEOF

# Run init.sql for table creation
if [ -f /opt/companion/supabase/db/init.sql ]; then
    echo "[init] Running init.sql..."
    psql -h /var/run/postgresql -U postgres -d postgres -f /opt/companion/supabase/db/init.sql
fi

# Grant table permissions
psql -h /var/run/postgresql -U postgres -d postgres << 'SQLEOF'
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA hivemind TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA hivemind TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA vexa TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA vexa TO anon, authenticated, service_role;
SQLEOF

echo "[init] PostgreSQL initialization complete."

# ── Initialize Qdrant config ─────────────────────────────────────────────────
cat > /opt/companion/config/qdrant.yaml << 'QEOF'
service:
  api_key: qdrant-dev-key
storage:
  storage_path: /var/lib/qdrant/storage
  snapshots_path: /var/lib/qdrant/snapshots
QEOF

echo "[init] Qdrant config created."

# ── Pull Ollama embedding model ──────────────────────────────────────────────
echo "[init] Pulling Ollama embedding model (${EMBEDDING_MODEL:-nomic-embed-text})..."
ollama pull "${EMBEDDING_MODEL:-nomic-embed-text}" 2>&1 || echo "[warn] Failed to pull embedding model"
echo "[init] Ollama model ready."

# ── Initialize Redis config ──────────────────────────────────────────────────
cat > /opt/companion/config/redis.conf << 'REOF'
bind 127.0.0.1
port 6379
dir /var/lib/redis
appendonly yes
appendfsync everysec
REOF

echo "[init] Redis config created."

# ── Initialize nginx config ──────────────────────────────────────────────────
cat > /etc/nginx/sites-available/default << 'NGEOF'
server {
    listen 8000;
    server_name _;

    # Supabase REST API
    location /rest/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Supabase Auth
    location /auth/ {
        proxy_pass http://127.0.0.1:9999/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Supabase Realtime
    location /realtime/ {
        proxy_pass http://127.0.0.1:4000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Supabase Storage
    location /storage/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Supabase Edge Functions
    location /functions/ {
        proxy_pass http://127.0.0.1:9000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGEOF

echo "[init] nginx config created."

# ── Stop temporary PostgreSQL (supervisord will start it) ────────────────────
pg_ctlcluster 15 main stop 2>/dev/null || true

echo ""
echo "[init] All services initialized. Starting supervisor..."
echo ""

exec "$@"
