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
      echo '--- sandbox mount | head ---'
      "${COMPOSE[@]}" exec -T sandbox sh -lc 'mount | head -40' 2>&1
      echo '--- sandbox /home/node ls -la ---'
      "${COMPOSE[@]}" exec -T sandbox ls -la /home/node 2>&1
    } || true
  fi
  "${COMPOSE[@]}" down >/dev/null 2>&1 || true
  rm -rf "$ROOT/runtime/home/.persist-test" \
         "$ROOT/runtime/home/.opencode-verify-test" \
         "$ROOT/runtime/home/.test-ephemeral-verify" 2>/dev/null || true
}

trap cleanup EXIT

# --- bin/agent-sandbox is cwd-independent + PATH/symlink-safe ---------------
# Done before `up` so we don't pay extra container churn. doctor() only checks
# paths under $ROOT, so passing from /tmp proves ROOT resolution worked.
(
  cd /tmp
  "$ROOT/bin/agent-sandbox" doctor >/dev/null
  PATH="$ROOT/bin:$PATH" agent-sandbox doctor >/dev/null
)
tmplink=$(mktemp -d)
ln -s "$ROOT/bin/agent-sandbox" "$tmplink/agent-sandbox"
( cd /tmp && "$tmplink/agent-sandbox" doctor >/dev/null )
rm -rf "$tmplink"

"$ROOT/bin/agent-sandbox" up

# --- network plane (unchanged) ----------------------------------------------

"${COMPOSE[@]}" exec -T sandbox sh -c 'command -v curl' >/dev/null
"${COMPOSE[@]}" exec -T sandbox curl --fail --silent --show-error -I https://registry.npmjs.org >/dev/null

if "${COMPOSE[@]}" exec -T sandbox curl --fail --silent --show-error -I --max-time 10 https://api.github.com >/dev/null; then
  echo "verify: expected api.github.com to be blocked but it succeeded" >&2
  exit 1
fi

"${COMPOSE[@]}" exec -T sandbox curl --fail --silent --show-error http://mcp-gateway:8080/status >/dev/null
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test "$MCP_GITHUB_URL" = "http://mcp-gateway:8080/servers/github/mcp"'
"${COMPOSE[@]}" exec -T sandbox sh -lc '[ -z "${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]'

# --- read-only root + PATH safety (unchanged) -------------------------------

"${COMPOSE[@]}" exec -T sandbox sh -lc 'mount | grep " on / type " | grep -q "(ro,"'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'case ":$PATH:" in *":/tool-bin:"*|*":/tool-bin/managed:"*|*":/home/node/.local/bin:"*|*":/workspace/bin:"*) exit 1;; esac'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'case ":$PATH:" in *":/tool-bin/user/bin:"*) :;; *) exit 1;; esac'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'case ":$PATH:" in *":/tool-bin/user/npm-global/bin:"*) :;; *) exit 1;; esac'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -w /state && test -w /cache && test -w /logs && test -w /tool-bin/managed && test -w /tool-bin/user/bin && test -w /tool-bin/user/npm-global'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test "$NPM_CONFIG_PREFIX" = "/tool-bin/user/npm-global"'

# --- new persistence layout: home is bind mount, denylist symlinks in place -

# /home/node is a bind mount, NOT tmpfs.
"${COMPOSE[@]}" exec -T sandbox sh -lc 'fs=$(stat -f -c %T /home/node); test "$fs" != tmpfs'

# Denylist symlinks (caches + IDE servers) are in place at every start.
"${COMPOSE[@]}" exec -T sandbox sh -lc '
  set -e
  for entry in \
    ".cache:/cache/xdg" \
    ".npm:/cache/npm" \
    ".pnpm-store:/cache/pnpm-store" \
    ".vscode-server:/state/dev-cache/vscode-server" \
    ".cursor-server:/state/dev-cache/cursor-server" \
    ".nix-portable:/state/dev-cache/nix-portable" \
    ".claude/cache:/cache/claude"; do
    rel=${entry%%:*}
    target=${entry#*:}
    test -L "$HOME/$rel" || { echo "verify: $HOME/$rel not a symlink" >&2; exit 1; }
    actual=$(readlink "$HOME/$rel")
    test "$actual" = "$target" || { echo "verify: $HOME/$rel -> $actual (want $target)" >&2; exit 1; }
  done
'

# Old /state/entrypoints layer is gone; /state/dev-cache is the new disposable bucket.
"${COMPOSE[@]}" exec -T sandbox sh -lc '! test -d /state/entrypoints'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -d /state/dev-cache'

# Things previously stored under /state/{claude,codex,xdg,...} now live in $HOME directly.
# After fresh start they may be empty dirs (created lazily); just ensure $HOME is the bind mount.
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -d "$HOME"'
"${COMPOSE[@]}" exec -T sandbox sh -lc '! test -L "$HOME/.claude" || readlink "$HOME/.claude" | grep -qv "^/state/claude$"'

# XDG: explicit overrides removed; apps fall back to $HOME/.<x> defaults, which
# under the new layout means home (persistent) or, for $HOME/.cache, the
# ephemeral symlink that lands on /cache/xdg.
"${COMPOSE[@]}" exec -T sandbox sh -lc '
  config=${XDG_CONFIG_HOME:-$HOME/.config}
  cache=${XDG_CACHE_HOME:-$HOME/.cache}
  case "$config" in /home/node/*|"$HOME"/*) ;; *) echo "config dir outside home: $config" >&2; exit 1;; esac
  case "$cache"  in /home/node/*|"$HOME"/*|/cache/*) ;; *) echo "cache dir not home/cache: $cache" >&2; exit 1;; esac
  mkdir -p "$config" "$cache" && test -w "$config" && test -w "$cache"
'

# --- shell rc scaffold + env-loader (regenerated every start) ---------------

"${COMPOSE[@]}" exec -T sandbox ls -la /state/env.local /etc/agent-sandbox/env-loader.sh
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -r /state/env.local'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -r /etc/agent-sandbox/env-loader.sh'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q env-loader.sh /home/node/.zshenv'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q env-loader.sh /home/node/.profile'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q env-loader.sh /home/node/.bashrc'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q "/state/shell/zshenv.local" /home/node/.zshenv'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q "/state/shell/profile.local" /home/node/.profile'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q "/state/shell/bashrc.local" /home/node/.bashrc'

# Shell rc is regenerated every start: write garbage, restart, verify it's gone.
"${COMPOSE[@]}" exec -T sandbox sh -lc 'echo "echo VERIFY_GARBAGE" >> /home/node/.zshrc'
"${COMPOSE[@]}" restart sandbox >/dev/null
sleep 2
"${COMPOSE[@]}" exec -T sandbox sh -lc '! grep -q VERIFY_GARBAGE /home/node/.zshrc'

# /state/env.local round-trip (regression).
"${COMPOSE[@]}" exec -T sandbox sh -lc '
  set -e
  echo SB_VERIFY_X=ok >> /state/env.local
  out=$(sh -lc "printf %s \$SB_VERIFY_X")
  sed -i "/^SB_VERIFY_X=/d" /state/env.local
  test "$out" = ok
'

# --- new: home auto-tracks new dotdirs (bind mount lets host see them) ------

"${COMPOSE[@]}" exec -T sandbox sh -lc 'mkdir -p /home/node/.opencode-verify-test && echo hello > /home/node/.opencode-verify-test/marker'
test -f "$ROOT/runtime/home/.opencode-verify-test/marker"
test "$(cat "$ROOT/runtime/home/.opencode-verify-test/marker")" = hello
"${COMPOSE[@]}" exec -T sandbox rm -rf /home/node/.opencode-verify-test

# --- new: home contents survive container restart (not just stop+start) -----

"${COMPOSE[@]}" exec -T sandbox sh -lc 'echo persisted > /home/node/.persist-test'
"${COMPOSE[@]}" restart sandbox >/dev/null
sleep 2
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test "$(cat /home/node/.persist-test)" = persisted'
"${COMPOSE[@]}" exec -T sandbox rm -f /home/node/.persist-test

# --- new: user-extensible ephemeral list ------------------------------------

"${COMPOSE[@]}" exec -T sandbox sh -lc 'echo ".test-ephemeral-verify /tmp/test-ephemeral-target" >> /state/home-ephemeral.local'
"${COMPOSE[@]}" restart sandbox >/dev/null
sleep 2
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -L "$HOME/.test-ephemeral-verify"'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'readlink "$HOME/.test-ephemeral-verify" | grep -q /tmp/test-ephemeral-target'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'sed -i "/test-ephemeral-verify/d" /state/home-ephemeral.local'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'rm -f "$HOME/.test-ephemeral-verify"'

# Reserved paths are rejected: a malicious entry mapping .zshrc must not turn it into a symlink.
"${COMPOSE[@]}" exec -T sandbox sh -lc 'echo ".zshrc /tmp/zshrc-hijack" >> /state/home-ephemeral.local'
"${COMPOSE[@]}" restart sandbox >/dev/null
sleep 2
"${COMPOSE[@]}" exec -T sandbox sh -lc '! test -L /home/node/.zshrc'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'sed -i "/zshrc-hijack/d" /state/home-ephemeral.local'

# --- new: nix-portable smoke ------------------------------------------------

"${COMPOSE[@]}" exec -T sandbox sh -lc 'command -v nix-portable >/dev/null'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'nix-portable --help >/dev/null 2>&1 || nix-portable -h >/dev/null 2>&1 || test -x "$(command -v nix-portable)"'

# --- new: bundled mails CLI -------------------------------------------------

"${COMPOSE[@]}" exec -T sandbox sh -lc 'command -v mails >/dev/null'

echo "verify: ok"
