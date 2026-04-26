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
