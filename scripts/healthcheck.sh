#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

check() {
    local url="$1"
    local name="$2"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^[23] ]]; then
        echo -e "  ${GREEN}✓${NC} $name — HTTP $http_code"
        return 0
    else
        echo -e "  ${RED}✗${NC} $name — HTTP $http_code"
        return 1
    fi
}

check_container() {
    local name="$1"
    local status
    status=$(docker compose ps --format json "$name" 2>/dev/null | jq -r '.State' 2>/dev/null || echo "missing")
    if [[ "$status" == "running" ]]; then
        echo -e "  ${GREEN}✓${NC} $name — running"
        return 0
    else
        echo -e "  ${RED}✗${NC} $name — $status"
        return 1
    fi
}

echo "═══════════════════════════════════════════"
echo "  Companion Platform Health Check"
echo "═══════════════════════════════════════════"
echo ""

echo "Containers:"
check_container "companion-supabase-db"
check_container "companion-supabase-studio"
check_container "companion-supabase-kong"
check_container "companion-supabase-auth"
check_container "companion-supabase-rest"
check_container "companion-supabase-realtime"
check_container "companion-supabase-storage"
check_container "companion-supabase-meta"
check_container "companion-supabase-edge-functions"
check_container "companion-vexa-api-gateway"
check_container "companion-vexa-admin-api"
check_container "companion-vexa-bot-manager"
check_container "companion-vexa-whisperlive"
check_container "companion-vexa-transcription-collector"
check_container "companion-vexa-transcription-service"
check_container "companion-vexa-mcp"
check_container "companion-vexa-tts-service"
check_container "companion-vexa-redis"
check_container "companion-vexa-minio"
check_container "companion-hivemind"

echo ""
echo "HTTP Endpoints:"
check "http://localhost:3000" "Supabase Studio"
check "http://localhost:8000/rest/v1/" "Supabase REST API"
check "http://localhost:8056" "Vexa API Gateway"
check "http://localhost:8057" "Vexa Admin API"
check "http://localhost:9100/health" "Hivemind API"
check "http://localhost:18888" "Vexa MCP"
check "http://localhost:8123" "Vexa Transcription Collector"
check "http://localhost:9001" "Minio Console"

echo ""
echo "═══════════════════════════════════════════"
