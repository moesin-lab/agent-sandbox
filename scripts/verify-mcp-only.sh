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

"$ROOT/bin/agent-sandbox" up mcp-only
compose exec -T sandbox command -v curl >/dev/null

if compose exec -T sandbox curl --fail --silent --show-error -I https://api.github.com >/dev/null 2>"$ROOT/runtime/state/verify-mcp-only.err"; then
  echo "expected api.github.com to be blocked"
  exit 1
fi

if ! rg -q "Network is unreachable|Could not resolve host|Connection refused|Failed to connect|Proxy CONNECT aborted" "$ROOT/runtime/state/verify-mcp-only.err"; then
  echo "request failed, but not with an expected block signal"
  cat "$ROOT/runtime/state/verify-mcp-only.err"
  exit 1
fi

echo "verify-mcp-only: ok"
