#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/orchestration/compose.yaml"

cleanup() {
  docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1 || true
}

trap cleanup EXIT

"$ROOT/bin/agent-sandbox" up hybrid
docker compose -f "$COMPOSE_FILE" exec -T sandbox curl --fail --silent --show-error -I https://registry.npmjs.org >/dev/null
docker compose -f "$COMPOSE_FILE" exec -T mcp-web curl --fail --silent --show-error -I http://localhost:3102/health >/dev/null

echo "verify-hybrid: ok"
