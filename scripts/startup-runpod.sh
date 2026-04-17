#!/usr/bin/env bash
set -e
export DEBIAN_FRONTEND=noninteractive

W=/workspace/companion
mkdir -p $W/{data/postgresql,data/qdrant/storage,data/redis,data/minio,data/wl-recordings,logs/companion,logs/vexa,logs/whisperlive,config,venv,repo}

echo "=== 1. Install system deps (if needed) ==="
if ! command -v pg_isready &>/dev/null; then
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    postgresql-16 postgresql-16-pgvector redis-server \
    python3-pip python3-venv supervisor nginx curl wget \
    pkg-config libssl-dev libpq-dev build-essential 2>&1 | tail -3
fi

echo "=== 2. Install Rust (if needed) ==="
if ! command -v cargo &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tail -3
fi
export PATH="$HOME/.cargo/bin:$PATH"

echo "=== 2b. Install Node.js + Xvfb (if needed) ==="
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y --no-install-recommends nodejs xvfb 2>&1 | tail -3
fi

echo "=== 3. Install Qdrant (if needed) ==="
if ! command -v qdrant &>/dev/null; then
  curl -fsSL https://github.com/qdrant/qdrant/releases/download/v1.12.4/qdrant-x86_64-unknown-linux-gnu.tar.gz \
    -o /tmp/qdrant.tar.gz
  mkdir -p /opt/qdrant
  tar xzf /tmp/qdrant.tar.gz -C /opt/qdrant
  ln -sf /opt/qdrant/qdrant /usr/local/bin/qdrant
  rm /tmp/qdrant.tar.gz
fi

echo "=== 4. Install Minio (if needed) ==="
if ! command -v minio &>/dev/null; then
  curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio \
    -o /usr/local/bin/minio
  chmod +x /usr/local/bin/minio
fi

echo "=== 5. Clone repos (if needed) ==="
if [ ! -d $W/repo/companion-hivemind/.git ]; then
  git clone https://github.com/companion-lab/companion-hivemind.git $W/repo/companion-hivemind
fi
if [ ! -d $W/repo/companion-voice/.git ]; then
  git clone https://github.com/companion-lab/companion-voice.git $W/repo/companion-voice
fi
if [ ! -d $W/repo/companion-deployment/.git ]; then
  git clone https://github.com/companion-lab/companion-deployment.git $W/repo/companion-deployment
fi
# Pull latest
cd $W/repo/companion-hivemind && git pull || true
cd $W/repo/companion-voice && git pull || true
cd $W/repo/companion-deployment && git pull || true

echo "=== 6. Build hivemind (if needed) ==="
if [ ! -f $W/repo/companion-hivemind/target/release/companion-hivemind ]; then
  cd $W/repo/companion-hivemind
  cargo build --release 2>&1 | tail -3
fi
cp $W/repo/companion-hivemind/target/release/companion-hivemind /usr/local/bin/hivemind

echo "=== 6b. Build vexa-bot (if needed) ==="
cd $W/repo/companion-voice/services/vexa-bot
VEXA_BOT_BUILD_STAMP=$W/config/.vexa-bot-build-commit
CURRENT_VEXA_BOT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
SHOULD_BUILD_VEXA_BOT=false

if [ ! -f core/dist/docker.js ] || [ ! -f core/dist/browser-utils.global.js ]; then
  SHOULD_BUILD_VEXA_BOT=true
elif [ ! -f "$VEXA_BOT_BUILD_STAMP" ] || [ "$(cat "$VEXA_BOT_BUILD_STAMP" 2>/dev/null)" != "$CURRENT_VEXA_BOT_COMMIT" ]; then
  SHOULD_BUILD_VEXA_BOT=true
fi

if [ "$SHOULD_BUILD_VEXA_BOT" = true ]; then
  npm install 2>&1 | tail -3
  npm run build 2>&1 | tail -3
  echo "$CURRENT_VEXA_BOT_COMMIT" > "$VEXA_BOT_BUILD_STAMP"
else
  echo "vexa-bot build already up-to-date for commit $CURRENT_VEXA_BOT_COMMIT"
fi

# Ensure Playwright Chromium is installed for browser automation
if [ ! -d "$HOME/.cache/ms-playwright/chromium-1208" ] && [ ! -d "$HOME/.cache/ms-playwright/chromium_headless_shell-1208" ]; then
  cd $W/repo/companion-voice/services/vexa-bot
  npx playwright install chromium 2>&1 | tail -3
fi

# Start virtual display for browser automation (idempotent)
if ! pgrep -f "Xvfb :99" >/dev/null; then
  rm -f /tmp/.X99-lock || true
  Xvfb :99 -screen 0 1280x720x24 -ac >/tmp/xvfb.log 2>&1 &
  sleep 1
fi

echo "=== 7. Set up Python venv ==="
if [ ! -f $W/venv/bin/uvicorn ]; then
  python3 -m venv $W/venv
  $W/venv/bin/pip install --upgrade pip
  $W/venv/bin/pip install /root/PPI/companion-voice/libs/shared-models/ 2>/dev/null || \
  $W/venv/bin/pip install $W/repo/companion-voice/libs/shared-models/ 2>&1 | tail -3
  $W/venv/bin/pip install fastapi uvicorn uvloop httptools \
    psycopg2-binary redis httpx alembic minio \
    python-multipart websockets pydantic pydantic-settings \
    aiofiles sse-starlette starlette 2>&1 | tail -3
  # Install per-service deps
  for svc in api-gateway admin-api bot-manager transcription-collector mcp tts-service; do
    if [ -f $W/repo/companion-voice/services/$svc/requirements.txt ]; then
      $W/venv/bin/pip install -r $W/repo/companion-voice/services/$svc/requirements.txt 2>&1 | tail -1 || true
    fi
  done
fi

# WhisperLive runtime deps (needed for live transcription on port 9090)
if ! $W/venv/bin/python -c "import faster_whisper" >/dev/null 2>&1; then
  $W/venv/bin/pip install -r $W/repo/companion-voice/services/WhisperLive/requirements/server.txt 2>&1 | tail -3
fi
mkdir -p /opt/companion
ln -sf $W/venv /opt/companion/venv

echo "=== 8. Generate secrets (persist in $W/config/.secrets) ==="
SECRETS_FILE=$W/config/.secrets
if [ ! -f $SECRETS_FILE ]; then
  JWT_SECRET=$(openssl rand -hex 32)
  ENC_SECRET=$(openssl rand -hex 32)
  cat > $SECRETS_FILE << EOF
HIVEMIND_JWT_SECRET=$JWT_SECRET
HIVEMIND_ENCRYPTION_SECRET=$ENC_SECRET
EOF
  chmod 600 $SECRETS_FILE
fi
source $SECRETS_FILE

echo "=== 9. Configure PostgreSQL ==="
# Ensure cluster exists (ephemeral on pod restart)
if ! pg_lsclusters | grep -q '16.*main.*online'; then
  if ! pg_lsclusters | grep -q '16.*main'; then
    pg_createcluster 16 main
  fi
  # Trust auth for easy setup
  cat > /etc/postgresql/16/main/pg_hba.conf << 'PGEOF'
local   all   all                 trust
host    all   all   127.0.0.1/32  trust
host    all   all   ::1/128       trust
host    all   all   0.0.0.0/0     md5
PGEOF
  cat > /etc/postgresql/16/main/conf.d/companion.conf << 'PGEOF'
listen_addresses = '*'
port = 5432
max_connections = 100
shared_buffers = 256MB
PGEOF
  pg_ctlcluster 16 main start
  sleep 2
else
  echo "PostgreSQL already running"
fi

for i in $(seq 1 15); do
  pg_isready -h 127.0.0.1 -U supabase_admin 2>/dev/null && break
  sleep 1
done

# Create roles and schemas (idempotent)
psql -h 127.0.0.1 -U postgres -d postgres << 'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin SUPERUSER CREATEDB CREATEROLE LOGIN PASSWORD 'postgres';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS hivemind;
CREATE SCHEMA IF NOT EXISTS vexa;
GRANT ALL ON SCHEMA hivemind TO supabase_admin, anon, authenticated, service_role;
GRANT ALL ON SCHEMA vexa TO supabase_admin, anon, authenticated, service_role;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQL

# Run init.sql (idempotent)
INIT_SQL=$W/repo/companion-deployment/supabase/db/init.sql
if [ -f "$INIT_SQL" ]; then
  psql -h 127.0.0.1 -U supabase_admin -d postgres -f "$INIT_SQL" 2>&1 | tail -3 || true
fi

# Create Vexa tables (idempotent)
$W/venv/bin/python -c "
import sys,os
os.environ['DB_HOST']='127.0.0.1'
os.environ['DB_PORT']='5432'
os.environ['DB_NAME']='postgres'
os.environ['DB_USER']='supabase_admin'
os.environ['DB_PASSWORD']='postgres'
os.environ['DB_SCHEMA']='vexa'
os.environ['DB_SSL_MODE']='disable'
sys.path.insert(0,'$W/repo/companion-voice/libs/shared-models')
from shared_models.models import Base
from sqlalchemy import create_engine
engine = create_engine('postgresql+psycopg2://supabase_admin:postgres@127.0.0.1/postgres',connect_args={'options':'-csearch_path=vexa'})
Base.metadata.create_all(bind=engine)
engine.dispose()
" 2>&1 || echo "[warn] Vexa table creation via SQLAlchemy failed (may already exist)"

# Stamp alembic (idempotent)
cd $W/repo/companion-voice/libs/shared-models
DB_HOST=127.0.0.1 DB_PORT=5432 DB_NAME=postgres DB_USER=supabase_admin DB_PASSWORD=postgres DB_SCHEMA=vexa DB_SSL_MODE=disable \
  $W/venv/bin/alembic stamp head 2>&1 || true
cd /

# Create vexa admin (idempotent)
psql -h 127.0.0.1 -U supabase_admin -d postgres << 'SQL'
INSERT INTO vexa.users (email, name, max_concurrent_bots)
SELECT 'admin@companion.app', 'Admin', 5
WHERE NOT EXISTS (SELECT 1 FROM vexa.users WHERE email = 'admin@companion.app');
INSERT INTO vexa.api_tokens (token, user_id)
SELECT 'token', u.id FROM vexa.users u WHERE u.email = 'admin@companion.app'
AND NOT EXISTS (SELECT 1 FROM vexa.api_tokens WHERE token = 'token');
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA hivemind TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA hivemind TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA vexa TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA vexa TO anon, authenticated, service_role;
SQL

echo "=== 10. Write configs ==="
mkdir -p /var/log/companion /var/log/vexa /var/lib/redis

cat > $W/config/qdrant.yaml << 'EOF'
service:
  api_key: qdrant-dev-key
storage:
  storage_path: /workspace/companion/data/qdrant/storage
  snapshots_path: /workspace/companion/data/qdrant/snapshots
EOF

cat > $W/config/redis.conf << 'EOF'
bind 127.0.0.1
port 6379
dir /workspace/companion/data/redis
appendonly yes
appendfsync everysec
EOF

cat > $W/config/supervisord.conf << EOF
[supervisord]
nodaemon=true
logfile=$W/logs/companion/supervisord.log
pidfile=/var/run/supervisord.pid

[program:redis]
command=/usr/bin/redis-server $W/config/redis.conf
autostart=true
autorestart=true
stdout_logfile=$W/logs/companion/redis.log
stderr_logfile=$W/logs/companion/redis.err.log

[program:qdrant]
command=/usr/local/bin/qdrant --config-path $W/config/qdrant.yaml
autostart=true
autorestart=true
stdout_logfile=$W/logs/companion/qdrant.log
stderr_logfile=$W/logs/companion/qdrant.err.log
startsecs=2

[program:minio]
command=/usr/local/bin/minio server $W/data/minio --console-address ":9001"
environment=MINIO_ROOT_USER="vexa-access-key",MINIO_ROOT_PASSWORD="vexa-secret-key"
autostart=true
autorestart=true
stdout_logfile=$W/logs/companion/minio.log
stderr_logfile=$W/logs/companion/minio.err.log
startsecs=2

[program:vexa-whisperlive]
command=$W/venv/bin/python run_server.py --port 9090 --backend faster_whisper --omp_num_threads 4
directory=$W/repo/companion-voice/services/WhisperLive
environment=REDIS_STREAM_URL="redis://127.0.0.1:6379/0/transcription_segments",TRANSCRIPTION_COLLECTOR_URL="http://127.0.0.1:8124",REDIS_HOST="127.0.0.1",REDIS_PORT="6379",REDIS_DB="0",REDIS_STREAM_NAME="transcription_segments",WL_RECORDING_DIR="$W/data/wl-recordings",WL_RECORDING_UPLOAD_URL="http://127.0.0.1:8080/internal/recordings/upload",DEVICE_TYPE="remote"
autostart=true
autorestart=true
stdout_logfile=$W/logs/whisperlive/whisperlive.log
stderr_logfile=$W/logs/whisperlive/whisperlive.err.log
startsecs=6

[program:hivemind]
command=/usr/local/bin/hivemind
environment=DB_HOST="127.0.0.1",DB_PORT="5432",DB_NAME="postgres",DB_USER="supabase_admin",DB_PASSWORD="postgres",DB_SCHEMA="hivemind",JWT_SECRET="$HIVEMIND_JWT_SECRET",JWT_TTL_SECONDS="2592000",ENCRYPTION_SECRET="$HIVEMIND_ENCRYPTION_SECRET",VEXA_API_URL="http://127.0.0.1:8056",VEXA_ADMIN_API_URL="http://127.0.0.1:8057",VEXA_ADMIN_TOKEN="token",EMBEDDING_API_URL="http://127.0.0.1:11434",EMBEDDING_MODEL="nomic-embed-text",QDRANT_URL="http://127.0.0.1:6334",QDRANT_API_KEY="qdrant-dev-key",HOST="0.0.0.0",PORT="9100"
autostart=true
autorestart=true
stdout_logfile=$W/logs/companion/hivemind.log
stderr_logfile=$W/logs/companion/hivemind.err.log
startsecs=3

[program:vexa-api-gateway]
command=$W/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8056
directory=$W/repo/companion-voice/services/api-gateway
environment=ADMIN_API_URL="http://127.0.0.1:8057",BOT_MANAGER_URL="http://127.0.0.1:8080",TRANSCRIPTION_COLLECTOR_URL="http://127.0.0.1:8124",MCP_URL="http://127.0.0.1:18888",REDIS_URL="redis://127.0.0.1:6379/0",PUBLIC_BASE_URL="http://127.0.0.1:8056",DB_HOST="127.0.0.1",DB_PORT="5432",DB_NAME="postgres",DB_USER="supabase_admin",DB_PASSWORD="postgres",DB_SCHEMA="vexa",DB_SSL_MODE="disable"
autostart=true
autorestart=true
stdout_logfile=$W/logs/vexa/api-gateway.log
stderr_logfile=$W/logs/vexa/api-gateway.err.log
startsecs=5

[program:vexa-admin-api]
command=$W/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8057
directory=$W/repo/companion-voice/services/admin-api
environment=DB_HOST="127.0.0.1",DB_PORT="5432",DB_NAME="postgres",DB_USER="supabase_admin",DB_PASSWORD="postgres",DB_SCHEMA="vexa",DB_SSL_MODE="disable",ADMIN_API_TOKEN="token"
autostart=true
autorestart=true
stdout_logfile=$W/logs/vexa/admin-api.log
stderr_logfile=$W/logs/vexa/admin-api.err.log
startsecs=3

[program:vexa-bot-manager]
command=$W/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8080
directory=$W/repo/companion-voice/services/bot-manager
environment=REDIS_URL="redis://127.0.0.1:6379/0",TTS_SERVICE_URL="http://127.0.0.1:8002",DB_HOST="127.0.0.1",DB_PORT="5432",DB_NAME="postgres",DB_USER="supabase_admin",DB_PASSWORD="postgres",DB_SCHEMA="vexa",DB_SSL_MODE="disable",ADMIN_TOKEN="token",ORCHESTRATOR="process",BOT_SCRIPT_PATH="$W/repo/companion-voice/services/vexa-bot/core/dist/docker.js",BOT_WORKING_DIR="$W/repo/companion-voice/services/vexa-bot/core",DISPLAY=":99",WHISPER_LIVE_URL="ws://127.0.0.1:9090/ws",TRANSCRIPTION_COLLECTOR_URL="http://127.0.0.1:8124",STORAGE_BACKEND="minio",MINIO_ENDPOINT="127.0.0.1:9000",MINIO_ACCESS_KEY="vexa-access-key",MINIO_SECRET_KEY="vexa-secret-key",MINIO_BUCKET="vexa-recordings",BOT_CALLBACK_BASE_URL="http://127.0.0.1:8080",BOT_CALLBACK_URL="http://127.0.0.1:8080/bots/internal/callback/exited",BOT_RECORDING_UPLOAD_URL="http://127.0.0.1:8080/internal/recordings/upload",PROCESS_LOGS_DIR="$W/logs/vexa-bots"
autostart=true
autorestart=true
stdout_logfile=$W/logs/vexa/bot-manager.log
stderr_logfile=$W/logs/vexa/bot-manager.err.log
startsecs=5

[program:vexa-transcription-collector]
command=$W/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8124
directory=$W/repo/companion-voice/services/transcription-collector
environment=DB_HOST="127.0.0.1",DB_PORT="5432",DB_NAME="postgres",DB_USER="supabase_admin",DB_PASSWORD="postgres",DB_SCHEMA="vexa",DB_SSL_MODE="disable",REDIS_HOST="127.0.0.1",REDIS_PORT="6379",ADMIN_TOKEN="token",STORAGE_BACKEND="minio",MINIO_ENDPOINT="127.0.0.1:9000",MINIO_ACCESS_KEY="vexa-access-key",MINIO_SECRET_KEY="vexa-secret-key",MINIO_BUCKET="vexa-recordings"
autostart=true
autorestart=true
stdout_logfile=$W/logs/vexa/transcription-collector.log
stderr_logfile=$W/logs/vexa/transcription-collector.err.log
startsecs=5

[program:vexa-mcp]
command=$W/venv/bin/uvicorn main:app --host 0.0.0.0 --port 18888
directory=$W/repo/companion-voice/services/mcp
environment=API_GATEWAY_URL="http://127.0.0.1:8056"
autostart=true
autorestart=true
stdout_logfile=$W/logs/vexa/mcp.log
stderr_logfile=$W/logs/vexa/mcp.err.log
startsecs=3

[program:vexa-tts-service]
command=$W/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8002
directory=$W/repo/companion-voice/services/tts-service
environment=OPENAI_API_KEY="",OPENAI_BASE_URL="https://api.openai.com"
autostart=true
autorestart=true
stdout_logfile=$W/logs/vexa/tts-service.log
stderr_logfile=$W/logs/vexa/tts-service.err.log
startsecs=3
EOF

echo "=== 11. Start supervisord ==="
# Kill any existing supervisor
pkill supervisord 2>/dev/null || true
sleep 1
supervisord -c $W/config/supervisord.conf
sleep 8
supervisorctl -c $W/config/supervisord.conf status

echo ""
echo "=== Companion platform is running! ==="
echo "Hivemind API:   http://127.0.0.1:9100"
echo "Vexa API:       http://127.0.0.1:8056"
echo "Vexa Admin:     http://127.0.0.1:8057"
echo "Vexa MCP:       http://127.0.0.1:18888"
echo "Qdrant:         http://127.0.0.1:6333"
echo "Minio:          http://127.0.0.1:9000"
echo "Redis:          127.0.0.1:6379"
echo "PostgreSQL:     127.0.0.1:5432"
echo ""
echo "JWT Secret:     $HIVEMIND_JWT_SECRET"
echo "Enc Secret:     $HIVEMIND_ENCRYPTION_SECRET"
