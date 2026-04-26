#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/orchestration/compose.yaml"
set -a
# shellcheck disable=SC1091
source "$ROOT/config/defaults.env"
set +a

compose() {
  docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

cleanup() {
  compose down >/dev/null 2>&1 || true
}

trap cleanup EXIT

"$ROOT/bin/agent-sandbox" up hybrid
compose exec -T sandbox command -v curl >/dev/null
compose exec -T sandbox curl --fail --silent --show-error -I https://registry.npmjs.org >/dev/null
compose exec -T sandbox curl --fail --silent --show-error http://mcp-web:3102/health >/dev/null

echo "verify-hybrid: ok"
