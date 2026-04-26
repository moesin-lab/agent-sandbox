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

"$ROOT/bin/agent-sandbox" up proxy-gated
compose exec -T sandbox command -v curl >/dev/null
compose exec -T sandbox curl --fail --silent --show-error -I https://registry.npmjs.org >/dev/null

if compose exec -T sandbox curl --fail --silent --show-error -I https://api.github.com >/dev/null 2>"$ROOT/runtime/state/verify-proxy-gated.err"; then
  echo "expected api.github.com to be blocked"
  exit 1
fi

if ! rg -q "403|Access Denied|Proxy CONNECT aborted|Failed to connect|Connection refused" "$ROOT/runtime/state/verify-proxy-gated.err"; then
  echo "request failed, but not with an expected proxy block signal"
  cat "$ROOT/runtime/state/verify-proxy-gated.err"
  exit 1
fi

echo "verify-proxy-gated: ok"
