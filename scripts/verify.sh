#!/usr/bin/env bash
set -euo pipefail

trap 'echo "verify: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/compose.yaml")

cleanup() {
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "verify: failure (rc=$rc), dumping diagnostics before teardown" >&2
    {
      echo '--- docker compose ps -a ---'
      "${COMPOSE[@]}" ps -a
      echo '--- docker compose logs (tail=300) ---'
      "${COMPOSE[@]}" logs --tail=300
      echo '--- proxy iptables nat ---'
      "${COMPOSE[@]}" exec -T proxy iptables -t nat -L -n -v 2>&1
      echo '--- sandbox /etc/resolv.conf ---'
      "${COMPOSE[@]}" exec -T sandbox cat /etc/resolv.conf 2>&1
      echo '--- sandbox getent hosts mcp-gateway ---'
      "${COMPOSE[@]}" exec -T sandbox getent hosts mcp-gateway 2>&1
    } || true
  fi
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

# Persistence boundaries.
"${COMPOSE[@]}" exec -T sandbox sh -lc 'mount | grep " on /home/node " | grep -q tmpfs'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'mount | grep " on / type " | grep -q "(ro,"'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test "$XDG_CONFIG_HOME" = "/state/xdg/config" && test "$XDG_CACHE_HOME" = "/cache/xdg"'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'case ":$PATH:" in *":/tool-bin:"*|*":/tool-bin/managed:"*|*":/home/node/.local/bin:"*|*":/workspace/bin:"*) exit 1;; esac'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'case ":$PATH:" in *":/tool-bin/user/bin:"*) :;; *) exit 1;; esac'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'case ":$PATH:" in *":/tool-bin/user/npm-global/bin:"*) :;; *) exit 1;; esac'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -w /state && test -w /cache && test -w /logs && test -w /tool-bin/managed && test -w /tool-bin/user/bin && test -w /tool-bin/user/npm-global'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test "$NPM_CONFIG_PREFIX" = "/tool-bin/user/npm-global"'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -L "$HOME/.claude" && test -L "$HOME/.cache" && test -d "$HOME/.local/bin" && test ! -L "$HOME/.local/bin"'

# Persistence扩展点结构性检查：env-loader + shell rc local 钩子已就位。
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -r /state/env.local && test -r /etc/agent-sandbox/env-loader.sh'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q env-loader.sh /home/node/.zshenv && grep -q env-loader.sh /home/node/.profile && grep -q env-loader.sh /home/node/.bashrc'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q "/state/shell/zshenv.local" /home/node/.zshenv && grep -q "/state/shell/profile.local" /home/node/.profile && grep -q "/state/shell/bashrc.local" /home/node/.bashrc'

# /state/env.local 行为性 round-trip：写一行 sentinel，新 login shell 应该 export 出来；测完清理。
"${COMPOSE[@]}" exec -T sandbox sh -lc '
  set -e
  echo SB_VERIFY_X=ok >> /state/env.local
  out=$(sh -lc "printf %s \$SB_VERIFY_X")
  sed -i "/^SB_VERIFY_X=/d" /state/env.local
  test "$out" = ok
'

echo "verify: ok"
