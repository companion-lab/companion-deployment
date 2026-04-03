# Companion Platform Deployment

Unified Docker Compose deployment for the Companion AI platform — Supabase, Vexa (companion-voice), and Hivemind in one stack.

## Quick Start

```bash
# 1. Setup (generates secrets, creates .env)
./scripts/setup.sh

# 2. Review and edit .env with your API keys
vim .env

# 3. Start everything
./scripts/manage.sh start

# 4. Verify
./scripts/healthcheck.sh
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Docker Compose Stack                         │
│                                                                 │
│  ┌───────────────────┐  ┌────────────────────────────────────┐ │
│  │  Supabase Stack   │  │     Companion-Voice (Vexa)         │ │
│  │                   │  │                                    │ │
│  │  supabase-db ◄────┼──┼─► api-gateway / admin-api          │ │
│  │  supabase-auth    │  │  bot-manager / whisperlive         │ │
│  │  supabase-kong    │  │  transcription-service/collector   │ │
│  │  supabase-rest    │  │  mcp / tts-service                 │ │
│  │  supabase-realtime│  │  redis / minio                     │ │
│  │  supabase-storage │  └────────────────────────────────────┘ │
│  │  supabase-meta    │                                        │
│  │  edge-functions   │  ┌────────────────────────────────────┐ │
│  │  imgproxy         │  │   Companion-Hivemind (Rust/Axum)   │ │
│  └───────────────────┘  │                                    │ │
│                         │  Company/org management            │ │
│                         │  Auth + JWT                        │ │
│                         │  Knowledge ingestion & FTS search  │ │
│                         │  Meeting transcripts               │ │
│                         │  Vexa integration proxy            │ │
│                         └────────────────────────────────────┘ │
│                                                                 │
│  Shared Network: companion-network                              │
│  Shared DB: supabase-db (PostgreSQL 15)                         │
│    - public: Supabase system                                    │
│    - hivemind: Company/org/knowledge tables                     │
│    - vexa: Meeting intelligence tables                          │
└─────────────────────────────────────────────────────────────────┘
```

## Services & Ports

| Service | Port | Description |
|---------|------|-------------|
| **supabase-db** | 5432 | PostgreSQL 15 (shared database) |
| **supabase-studio** | 3000 | Supabase dashboard UI |
| **supabase-kong** | 8000 | API gateway (auth, rest, realtime, storage) |
| **supabase-rest** | — | PostgREST REST API |
| **supabase-auth** | — | GoTrue authentication |
| **supabase-realtime** | — | Realtime WebSocket subscriptions |
| **supabase-storage** | — | File storage API |
| **supabase-meta** | — | Postgres metadata API |
| **supabase-edge-functions** | — | Deno edge functions |
| **supabase-imgproxy** | — | Image transformation |
| **vexa-api-gateway** | 8056 | Vexa main API entry point |
| **vexa-admin-api** | 8057 | Vexa admin/user management |
| **vexa-bot-manager** | — | Meeting bot orchestration |
| **vexa-whisperlive** | — | Real-time audio streaming |
| **vexa-transcription-collector** | 8123 | Transcription segment collector |
| **vexa-transcription-service** | — | Whisper speech-to-text |
| **vexa-mcp** | 18888 | MCP server for AI agents |
| **vexa-tts-service** | — | Text-to-speech |
| **vexa-redis** | — | Redis streams for transcription |
| **vexa-minio** | 9000/9001 | S3-compatible recording storage |
| **companion-hivemind** | 9100 | Rust backend for company/org management |

## Management Scripts

```bash
# Start all services
./scripts/manage.sh start

# Stop services (keep data)
./scripts/manage.sh stop

# Stop and remove containers
./scripts/manage.sh down

# Destroy everything (databases, recordings, etc.)
./scripts/manage.sh down-volumes

# View status and resource usage
./scripts/manage.sh status

# Follow logs
./scripts/manage.sh logs
./scripts/manage.sh logs vexa-api-gateway

# Health checks
./scripts/healthcheck.sh

# Backup databases
./scripts/manage.sh backup

# Restore from backup
./scripts/manage.sh restore backups/supabase_20260401_120000.sql

# Open shell in a container
./scripts/manage.sh shell supabase-db

# Open psql shell
./scripts/manage.sh db-shell
```

## Database Schema

All services share a single PostgreSQL instance with three schemas:

### `public` — Supabase system tables
Managed by Supabase. Auth users, realtime subscriptions, storage metadata.

### `hivemind` — Company/Org management
| Table | Purpose |
|-------|---------|
| `companies` | Top-level organizations |
| `users` | User accounts (bcrypt passwords) |
| `company_members` | User-company memberships with roles |
| `company_invites` | Email-based invite system |
| `company_config` | Per-company settings (models, providers) |
| `member_api_keys` | Encrypted API keys per member/provider |
| `meetings` | Meeting records with Vexa linkage |
| `knowledge_chunks` | Chunked transcripts with embeddings + FTS |
| `token_usage` | LLM token usage tracking |
| `auth_tokens` | Session tokens for hivemind API |

### `vexa` — Meeting intelligence
| Table | Purpose |
|-------|---------|
| `users` | Vexa API users |
| `api_tokens` | Vexa API tokens |
| `meetings` | Meeting records with bot status |
| `transcriptions` | Real-time transcription segments |
| `meeting_sessions` | Session tracking |
| `recordings` | Recording metadata |
| `media_files` | Individual media artifacts |
| `transcription_jobs` | Batch transcription jobs |

## Configuration

### Required Environment Variables

Copy `.env.example` to `.env` and set:

```bash
# Supabase
SUPABASE_DB_PASSWORD=          # PostgreSQL password
SUPABASE_JWT_SECRET=           # JWT signing secret (auto-generated by setup.sh)
SUPABASE_ANON_KEY=             # Supabase anon key
SUPABASE_SERVICE_KEY=          # Supabase service role key

# Vexa
VEXA_ADMIN_API_TOKEN=          # Admin API token for Vexa
VEXA_TRANSCRIBER_API_KEY=      # Transcription service API key
ZOOM_CLIENT_ID=                # Zoom OAuth (optional)
ZOOM_CLIENT_SECRET=            # Zoom OAuth (optional)
OPENAI_API_KEY=                # For TTS (optional)

# Hivemind
HIVEMIND_JWT_SECRET=           # JWT secret (auto-generated by setup.sh)
HIVEMIND_ENCRYPTION_SECRET=    # API key encryption (auto-generated by setup.sh)

# Storage
MINIO_ACCESS_KEY=              # Minio/S3 access key
MINIO_SECRET_KEY=              # Minio/S3 secret key
```

### Path Configuration

The docker-compose uses relative paths to companion-voice and companion-hivemind repos:

```bash
# In .env, adjust paths if your repos are elsewhere
COMPAVION_VOICE_PATH=../companion-voice
HIVEMIND_PATH=../companion-hivemind
```

## Reverse Proxy (Nginx)

A sample Nginx configuration is provided in `configs/nginx.conf` for production deployments:

```bash
sudo cp configs/nginx.conf /etc/nginx/sites-available/companion-platform
sudo ln -s /etc/nginx/sites-available/companion-platform /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

This routes:
- `/auth/*`, `/rest/*`, `/realtime/*`, `/storage/*` → Supabase
- `/vexa/*` → Vexa API
- `/hivemind/*` → Hivemind API
- `/` → Supabase Studio

## Backup & Restore

### Automatic backups

```bash
# Backup all schemas
./scripts/manage.sh backup

# Creates three files:
#   backups/supabase_YYYYMMDD_HHMMSS.sql   (full dump)
#   backups/hivemind_YYYYMMDD_HHMMSS.sql   (hivemind schema only)
#   backups/vexa_YYYYMMDD_HHMMSS.sql       (vexa schema only)
```

### Restore

```bash
./scripts/manage.sh restore backups/supabase_20260401_120000.sql
```

### Manual backup

```bash
docker compose exec supabase-db pg_dump -U postgres -d postgres > backup.sql
```

## Troubleshooting

### Service won't start

```bash
# Check logs
./scripts/manage.sh logs <service-name>

# Check container status
./scripts/manage.sh status

# Restart specific service
docker compose restart <service-name>
```

### Database connection issues

```bash
# Open psql shell
./scripts/manage.sh db-shell

# Check if DB is healthy
docker compose exec supabase-db pg_isready -U postgres
```

### Port conflicts

If a port is already in use, change it in `.env`:

```bash
SUPABASE_DB_PORT=5433          # Instead of 5432
VEXA_API_PORT=8058             # Instead of 8056
HIVEMIND_PORT=9101             # Instead of 9100
```

### Reset everything

```bash
# WARNING: Destroys all data
./scripts/manage.sh down-volumes

# Then start fresh
./scripts/manage.sh start
```

## Production Checklist

- [ ] Set strong `SUPABASE_DB_PASSWORD`
- [ ] Set strong `SUPABASE_JWT_SECRET` (64+ chars)
- [ ] Set strong `HIVEMIND_JWT_SECRET`
- [ ] Set strong `HIVEMIND_ENCRYPTION_SECRET`
- [ ] Set `VEXA_ADMIN_API_TOKEN` to a secure value
- [ ] Set `MINIO_ACCESS_KEY` and `MINIO_SECRET_KEY`
- [ ] Configure `SUPABASE_PUBLIC_URL` to your domain
- [ ] Set up SSL/TLS (Nginx + Let's Encrypt)
- [ ] Configure firewall rules (only expose needed ports)
- [ ] Set up automated backups (cron + `./scripts/manage.sh backup`)
- [ ] Configure resource limits in docker-compose.yml
- [ ] Set up monitoring (Prometheus + Grafana)
- [ ] Configure log rotation
