#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DEPLOY_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[SETUP]${NC} $*"; }

info "Setting up Companion Platform deployment..."

# Copy env if not exists
if [[ ! -f .env ]]; then
    info "Creating .env from .env.example..."
    cp .env.example .env
    warn "Please edit .env with your secrets before running 'docker compose up'"
else
    info ".env already exists, skipping"
fi

# Create backup dir
mkdir -p backups

# Generate secure JWT secret if still default
if grep -q "super-secret-jwt-token-with-at-least-32-characters-long" .env 2>/dev/null; then
    warn "Default JWT secret detected. Generating a secure one..."
    NEW_SECRET=$(openssl rand -base64 48 | tr -d '\n')
    sed -i "s|super-secret-jwt-token-with-at-least-32-characters-long|$NEW_SECRET|g" .env
    info "JWT secret updated"
fi

# Generate secure hivemind secrets if still default
if grep -q "hivemind-secret-change-me" .env 2>/dev/null; then
    warn "Default hivemind secret detected. Generating a secure one..."
    NEW_SECRET=$(openssl rand -hex 32)
    sed -i "s|hivemind-secret-change-me|$NEW_SECRET|g" .env
    info "Hivemind JWT secret updated"
fi

if grep -q "hivemind-encryption-secret-change-me" .env 2>/dev/null; then
    NEW_SECRET=$(openssl rand -hex 32)
    sed -i "s|hivemind-encryption-secret-change-me|$NEW_SECRET|g" .env
    info "Hivemind encryption secret updated"
fi

# Pull images
info "Pulling base images..."
docker compose pull --quiet 2>/dev/null || warn "Some images may need to be built"

info ""
info "Setup complete!"
info ""
info "Next steps:"
info "  1. Review and edit .env with your secrets (API keys, etc.)"
info "  2. Run: ./scripts/manage.sh start"
info "  3. Run: ./scripts/healthcheck.sh"
info ""
info "Default ports:"
info "  Supabase Studio:  3000"
info "  Supabase API:     8000"
info "  Vexa API:         8056"
info "  Vexa Admin:       8057"
info "  Hivemind API:     9100"
info "  Minio Console:    9001"
info "  Vexa MCP:         18888"
