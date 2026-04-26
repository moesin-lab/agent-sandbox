#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
# shellcheck disable=SC1091
source "$ROOT/config/defaults.env"
set +a

compose() {
  local args
  args=(-p "$COMPOSE_PROJECT_NAME" -f "$ROOT/compose.yaml")

  if [[ -f "$ROOT/$MCP_ENABLED_FILE" ]]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [[ -n "$line" ]] || continue
      args+=(-f "$ROOT/compose.mcp.${line}.yaml")
    done < "$ROOT/$MCP_ENABLED_FILE"
  fi

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
