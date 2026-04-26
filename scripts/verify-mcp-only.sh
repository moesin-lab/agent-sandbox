#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/orchestration/compose.yaml"

cleanup() {
  docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1 || true
}

trap cleanup EXIT

"$ROOT/bin/agent-sandbox" up mcp-only

if docker compose -f "$COMPOSE_FILE" exec -T sandbox curl --fail --silent --show-error -I https://api.github.com >/dev/null; then
  echo "expected api.github.com to be blocked"
  exit 1
fi

echo "verify-mcp-only: ok"
