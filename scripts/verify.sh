#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/compose.yaml")

cleanup() {
  "${COMPOSE[@]}" down >/dev/null 2>&1 || true
}

trap cleanup EXIT

"$ROOT/bin/agent-sandbox" up

# Tooling sanity.
"${COMPOSE[@]}" exec -T sandbox sh -c 'command -v curl' >/dev/null

# Default-allow: a target outside the blocklist passes through transparently
# (HTTPS via SNI splice).
"${COMPOSE[@]}" exec -T sandbox curl --fail --silent --show-error -I https://registry.npmjs.org >/dev/null

# Blocklisted target should be terminated by Squid (default blocklist contains
# api.github.com to force GitHub access through mcp-gateway).
if "${COMPOSE[@]}" exec -T sandbox curl --fail --silent --show-error -I --max-time 10 https://api.github.com >/dev/null; then
  echo "verify: expected api.github.com to be blocked but it succeeded" >&2
  exit 1
fi

# mcp-gateway is reachable directly (port 8080 not redirected).
"${COMPOSE[@]}" exec -T sandbox curl --fail --silent --show-error http://mcp-gateway:8080/status >/dev/null

# MCP URL env wiring.
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test "$MCP_GITHUB_URL" = "http://mcp-gateway:8080/servers/github/mcp"'

# Sandbox should NOT see HTTP_PROXY / HTTPS_PROXY anymore; transparent proxy is the only path.
"${COMPOSE[@]}" exec -T sandbox sh -lc '[ -z "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]'

echo "verify: ok"
