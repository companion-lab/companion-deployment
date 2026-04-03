#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Pre-flight checks ────────────────────────────────────────────────────────

check_prerequisites() {
    info "Checking prerequisites..."

    command -v docker >/dev/null 2>&1 || error "Docker is not installed"
    command -v docker compose >/dev/null 2>&1 || error "Docker Compose is not installed"

    local compose_version
    compose_version=$(docker compose version --short)
    info "Docker Compose version: $compose_version"

    if [[ ! -f .env ]]; then
        warn ".env not found. Copying from .env.example..."
        cp .env.example .env
        warn "Please edit .env with your secrets before starting."
        exit 1
    fi

    info "Prerequisites OK"
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_start() {
    check_prerequisites
    info "Starting Companion Platform..."
    docker compose up -d --build
    info "Waiting for services to be healthy..."
    sleep 5
    docker compose ps
    info ""
    info "Platform is starting. Services will be available at:"
    info "  Supabase Studio:  http://localhost:3000"
    info "  Supabase API:     http://localhost:8000"
    info "  Vexa API:         http://localhost:8056"
    info "  Vexa Admin:       http://localhost:8057"
    info "  Hivemind API:     http://localhost:9100"
    info "  Minio Console:    http://localhost:9001"
    info ""
    info "Check health: ./scripts/healthcheck.sh"
}

cmd_stop() {
    info "Stopping Companion Platform..."
    docker compose stop
    info "All services stopped"
}

cmd_down() {
    info "Shutting down Companion Platform..."
    docker compose down
    info "All services removed"
}

cmd_down_volumes() {
    warn "This will destroy ALL data including databases and recordings!"
    read -rp "Are you sure? (y/N) " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        info "Destroying all data and services..."
        docker compose down -v --remove-orphans
        info "All data destroyed"
    else
        info "Aborted"
    fi
}

cmd_restart() {
    info "Restarting Companion Platform..."
    docker compose restart
    info "Services restarted"
}

cmd_status() {
    info "Service Status:"
    echo ""
    docker compose ps
    echo ""
    info "Resource Usage:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" \
        $(docker compose ps -q) 2>/dev/null || warn "No running containers"
}

cmd_logs() {
    local service="${1:-}"
    if [[ -n "$service" ]]; then
        docker compose logs -f "$service"
    else
        docker compose logs -f
    fi
}

cmd_healthcheck() {
    info "Running health checks..."
    echo ""

    local all_ok=true

    check_service "supabase-db" "http://localhost:8000/rest/v1/" "Supabase DB+REST" || all_ok=false
    check_service "supabase-studio" "http://localhost:3000" "Supabase Studio" || all_ok=false
    check_service "vexa-api-gateway" "http://localhost:8056" "Vexa API" || all_ok=false
    check_service "companion-hivemind" "http://localhost:9100/health" "Hivemind API" || all_ok=false
    check_service "vexa-mcp" "http://localhost:18888" "Vexa MCP" || all_ok=false
    check_service "vexa-transcription-collector" "http://localhost:8123" "Vexa Transcription" || all_ok=false
    check_service "vexa-minio" "http://localhost:9001" "Minio Console" || all_ok=false

    echo ""
    if $all_ok; then
        info "All services healthy"
    else
        warn "Some services are not healthy. Check logs: ./scripts/manage.sh logs <service>"
    fi
}

check_service() {
    local container="$1"
    local url="$2"
    local name="$3"

    local container_status
    container_status=$(docker compose ps --format json "$container" 2>/dev/null | jq -r '.State' 2>/dev/null || echo "unknown")

    if [[ "$container_status" != "running" ]]; then
        echo -e "  ${RED}✗${NC} $name — container not running ($container_status)"
        return 1
    fi

    if command -v curl >/dev/null 2>&1; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$url" 2>/dev/null || echo "000")
        if [[ "$http_code" =~ ^[23] ]]; then
            echo -e "  ${GREEN}✓${NC} $name — HTTP $http_code"
            return 0
        else
            echo -e "  ${YELLOW}~${NC} $name — container running, HTTP $http_code (may still be starting)"
            return 1
        fi
    else
        echo -e "  ${GREEN}✓${NC} $name — container running"
        return 0
    fi
}

cmd_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$SCRIPT_DIR/backups"
    mkdir -p "$backup_dir"

    info "Backing up database to $backup_dir/supabase_$timestamp.sql..."
    docker compose exec -T supabase-db pg_dump -U postgres -d postgres --no-owner --no-privileges \
        > "$backup_dir/supabase_$timestamp.sql" 2>/dev/null

    info "Backing up hivemind schema..."
    docker compose exec -T supabase-db pg_dump -U postgres -d postgres \
        --schema=hivemind --no-owner --no-privileges \
        > "$backup_dir/hivemind_$timestamp.sql" 2>/dev/null

    info "Backing up vexa schema..."
    docker compose exec -T supabase-db pg_dump -U postgres -d postgres \
        --schema=vexa --no-owner --no-privileges \
        > "$backup_dir/vexa_$timestamp.sql" 2>/dev/null

    info "Backup complete:"
    ls -lh "$backup_dir/"*"$timestamp"*
}

cmd_restore() {
    local backup_file="${1:-}"
    if [[ -z "$backup_file" ]]; then
        error "Usage: $0 restore <backup-file.sql>"
    fi
    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
    fi

    warn "This will overwrite the current database!"
    read -rp "Are you sure? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Aborted"
        exit 0
    fi

    info "Restoring from $backup_file..."
    docker compose exec -T supabase-db psql -U postgres -d postgres < "$backup_file"
    info "Restore complete"
}

cmd_shell() {
    local service="${1:-supabase-db}"
    info "Opening shell in $service..."
    docker compose exec "$service" /bin/sh || docker compose exec "$service" /bin/bash
}

cmd_db_shell() {
    info "Opening psql shell..."
    docker compose exec supabase-db psql -U postgres -d postgres
}

# ─── Main ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Companion Platform Manager

Usage: $0 <command> [args]

Commands:
  start           Start all services (build + up -d)
  stop            Stop all services (keep data)
  down            Stop and remove containers
  down-volumes    Stop and destroy ALL data (databases, recordings, etc.)
  restart         Restart all services
  status          Show service status and resource usage
  logs [service]  Follow logs (optionally for a specific service)
  healthcheck     Run health checks on all services
  backup          Backup all databases to backups/
  restore <file>  Restore database from backup file
  shell [service] Open shell in a service container (default: supabase-db)
  db-shell        Open psql shell to the database
  help            Show this help

Examples:
  $0 start
  $0 logs vexa-api-gateway
  $0 healthcheck
  $0 backup
  $0 restore backups/supabase_20260401_120000.sql
EOF
}

case "${1:-help}" in
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    down)           cmd_down ;;
    down-volumes)   cmd_down_volumes ;;
    restart)        cmd_restart ;;
    status)         cmd_status ;;
    logs)           cmd_logs "${2:-}" ;;
    healthcheck)    cmd_healthcheck ;;
    backup)         cmd_backup ;;
    restore)        cmd_restore "${2:-}" ;;
    shell)          cmd_shell "${2:-}" ;;
    db-shell)       cmd_db_shell ;;
    help|--help|-h) usage ;;
    *)              error "Unknown command: $1. Run '$0 help' for usage." ;;
esac
