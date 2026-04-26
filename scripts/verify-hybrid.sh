#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
# shellcheck disable=SC1091
source "$ROOT/config/defaults.env"
set +a

compose() {
  local args compose_root
  compose_root="${COMPOSE_ROOT:-deploy/compose}"
  args=(-p "$COMPOSE_PROJECT_NAME" -f "$ROOT/$compose_root/compose.yaml")

  docker compose "${args[@]}" "$@"
}

cleanup() {
  compose down >/dev/null 2>&1 || true
}

trap cleanup EXIT

"$ROOT/bin/agent-sandbox" up hybrid
compose exec -T sandbox command -v curl >/dev/null
compose exec -T sandbox curl --fail --silent --show-error -I https://registry.npmjs.org >/dev/null
compose exec -T sandbox curl --fail --silent --show-error http://mcp-gateway:8080/status >/dev/null
compose exec -T sandbox sh -lc 'test "$MCP_GITHUB_URL" = "http://mcp-gateway:8080/servers/github/mcp"'

echo "verify-hybrid: ok"
