# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Build Hivemind (Rust)
# ─────────────────────────────────────────────────────────────────────────────
FROM rust:1.88-slim AS hivemind-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev libfontconfig1-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Step 1: Copy only Cargo files to cache dependency downloads
COPY companion-hivemind/Cargo.toml companion-hivemind/Cargo.lock ./

# Create dummy src to satisfy cargo build for dependency caching
RUN mkdir src && echo "fn main() {}" > src/main.rs

# Download and compile all dependencies (cached layer)
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release

# Step 2: Copy actual source code (invalidates only when src changes)
RUN rm -rf src
COPY companion-hivemind/src ./src
COPY companion-hivemind/migrations ./migrations

# Build the actual project (only recompiles changed code)
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/target \
    cargo build --release

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Final unified companion image
# ─────────────────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# ── Install system dependencies ──────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg supervisor zstd \
    postgresql-15 \
    redis-server \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# ── Install Ollama ───────────────────────────────────────────────────────────
RUN curl -fsSL https://ollama.com/install.sh | sh

# ── Install Qdrant ───────────────────────────────────────────────────────────
RUN curl -fsSL https://github.com/qdrant/qdrant/releases/download/v1.12.4/qdrant-x86_64-unknown-linux-gnu.tar.gz \
    -o /tmp/qdrant.tar.gz && \
    mkdir -p /opt/qdrant && \
    tar xzf /tmp/qdrant.tar.gz -C /opt/qdrant && \
    ln -s /opt/qdrant/qdrant /usr/local/bin/qdrant && \
    rm /tmp/qdrant.tar.gz

# ── Install Minio ────────────────────────────────────────────────────────────
RUN curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio \
    -o /usr/local/bin/minio && \
    chmod +x /usr/local/bin/minio

# ── Install nginx (API gateway replacement for Kong) ─────────────────────────
RUN apt-get update && apt-get install -y nginx && \
    rm -rf /var/lib/apt/lists/*

# ── Install Python deps for Vexa services ────────────────────────────────────
RUN python3 -m venv /opt/companion/venv
ENV PATH="/opt/companion/venv/bin:$PATH"

# Install shared-models library first (dependency of Vexa services)
COPY companion-voice/libs/shared-models /tmp/shared-models
RUN pip install --no-cache-dir /tmp/shared-models

# Install all Vexa service requirements
COPY companion-voice/services/api-gateway/requirements.txt /tmp/req-api-gateway.txt
COPY companion-voice/services/admin-api/requirements.txt /tmp/req-admin-api.txt
COPY companion-voice/services/bot-manager/requirements.txt /tmp/req-bot-manager.txt
COPY companion-voice/services/transcription-collector/requirements.txt /tmp/req-transcription-collector.txt
COPY companion-voice/services/mcp/requirements.txt /tmp/req-mcp.txt
COPY companion-voice/services/tts-service/requirements.txt /tmp/req-tts-service.txt
RUN pip install --no-cache-dir \
    -r /tmp/req-api-gateway.txt \
    -r /tmp/req-admin-api.txt \
    -r /tmp/req-bot-manager.txt \
    -r /tmp/req-transcription-collector.txt \
    -r /tmp/req-mcp.txt \
    -r /tmp/req-tts-service.txt

# ── Copy Hivemind binary ─────────────────────────────────────────────────────
COPY --from=hivemind-builder /app/target/release/companion-hivemind /usr/local/bin/hivemind

# ── Copy Vexa services ───────────────────────────────────────────────────────
COPY companion-voice/services /opt/companion/services

# ── Copy Supabase configs ────────────────────────────────────────────────────
COPY companion-deployment/supabase /opt/companion/supabase

# ── Create data & log directories ────────────────────────────────────────────
RUN mkdir -p \
    /var/lib/postgresql/data \
    /var/lib/qdrant/storage \
    /var/lib/redis \
    /var/lib/minio/data \
    /root/.ollama \
    /var/log/companion \
    /var/log/nginx \
    /var/log/postgresql \
    /var/log/redis \
    /var/log/minio \
    /var/log/hivemind \
    /var/log/vexa \
    /var/run/postgresql \
    /opt/companion/config

# ── PostgreSQL setup ─────────────────────────────────────────────────────────
RUN pg_createcluster 15 main --start 2>/dev/null || true && \
    pg_ctlcluster 15 main stop 2>/dev/null || true

# ── Supervisor config ────────────────────────────────────────────────────────
COPY companion-deployment/docker/single/supervisord.conf /etc/supervisor/conf.d/companion.conf

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY companion-deployment/docker/single/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Expose all service ports ─────────────────────────────────────────────────
EXPOSE 3000 5432 6333 6334 8000 8001 8056 8057 8124 9000 9001 9100 18888 11434

ENV HOST=0.0.0.0
ENV PORT=9100
ENV DB_HOST=localhost
ENV DB_PORT=5432
ENV DB_NAME=postgres
ENV DB_USER=supabase_admin
ENV DB_PASSWORD=postgres
ENV DB_SCHEMA=hivemind
ENV JWT_SECRET=952572608172ccb759c0107b1ea873c1c7b3e0561753effc1b9a0be15a22c512
ENV JWT_TTL_SECONDS=2592000
ENV ENCRYPTION_SECRET=7fc09e1cee970e2ab7fa4880a525998277712c393de94aa42cc725d3bad8081b
ENV VEXA_API_URL=http://localhost:8056
ENV VEXA_ADMIN_API_URL=http://localhost:8057
ENV VEXA_ADMIN_TOKEN=token
ENV EMBEDDING_API_URL=http://localhost:11434
ENV EMBEDDING_MODEL=nomic-embed-text
ENV QDRANT_URL=http://localhost:6334
ENV QDRANT_API_KEY=qdrant-dev-key

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
