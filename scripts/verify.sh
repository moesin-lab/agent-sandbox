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

# --- healthcheck + autoheal -------------------------------------------------
# proxy / mcp-gateway expose Docker healthchecks; sandbox depends on them
# being healthy, so reaching this point already proves they passed once.
# Re-assert anyway to catch a regression where depends_on is loosened.

proxy_cid=$("${COMPOSE[@]}" ps -q proxy)
test "$(docker inspect -f '{{.State.Health.Status}}' "$proxy_cid")" = "healthy"

mcp_cid=$("${COMPOSE[@]}" ps -q mcp-gateway)
test "$(docker inspect -f '{{.State.Health.Status}}' "$mcp_cid")" = "healthy"

# autoheal sidecar is up and on no network (only owns the docker socket).
autoheal_cid=$("${COMPOSE[@]}" ps -q autoheal)
test -n "$autoheal_cid"
test "$(docker inspect -f '{{.State.Status}}' "$autoheal_cid")" = "running"
test "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$autoheal_cid")" = "none"

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

# --- persistence layout: home is bind mount, no default symlink clutter -----

# /home/node is a bind mount, NOT tmpfs.
"${COMPOSE[@]}" exec -T sandbox sh -lc 'fs=$(stat -f -c %T /home/node); test "$fs" != tmpfs'

# Default cache/temp paths are tmpfs mounts under home, so high-churn payloads
# do not land in runtime/home and host-side home does not contain broken links.
"${COMPOSE[@]}" exec -T sandbox sh -lc '
  set -e
  for rel in \
    ".cache" \
    ".claude/cache" \
    ".claude/downloads" \
    ".codex/cache" \
    ".codex/.tmp" \
    ".codex/tmp" \
    ".codex/shell_snapshots"; do
    test -d "$HOME/$rel" || { echo "verify: $HOME/$rel is not a directory" >&2; exit 1; }
    ! test -L "$HOME/$rel" || { echo "verify: $HOME/$rel is still a symlink" >&2; exit 1; }
    fs=$(stat -f -c %T "$HOME/$rel")
    test "$fs" = tmpfs || { echo "verify: $HOME/$rel fs is $fs, want tmpfs" >&2; exit 1; }
  done
  for entry in \
    ".vscode-server:/state/dev-cache/vscode-server" \
    ".cursor-server:/state/dev-cache/cursor-server" \
    ".windsurf-server:/state/dev-cache/windsurf-server" \
    ".nix-portable:/state/dev-cache/nix-portable"; do
    rel=${entry%%:*}
    target=${entry#*:}
    if [ -L "$HOME/$rel" ]; then
      actual=$(readlink "$HOME/$rel")
      test "$actual" != "$target" || { echo "verify: $HOME/$rel is still default symlink to $target" >&2; exit 1; }
    fi
  done
'

# Old /state/entrypoints layer is gone; /state/dev-cache is the new disposable bucket.
"${COMPOSE[@]}" exec -T sandbox sh -lc '! test -d /state/entrypoints'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -d /state/dev-cache'

# Things previously stored under /state/{claude,codex,xdg,...} now live in $HOME directly.
# Active runtime paths should not keep the old state-backed compatibility layer.
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -d "$HOME"'
"${COMPOSE[@]}" exec -T sandbox sh -lc '
  set -e
  for entry in \
    ".claude:/state/claude" \
    ".claude.json:/state/claude.json" \
    ".codex:/state/codex" \
    ".memsearch:/state/memsearch" \
    ".config:/state/xdg/config" \
    ".local/share:/state/xdg/data" \
    ".local/state:/state/xdg/state" \
    ".ssh:/state/ssh" \
    ".gitconfig:/state/git/gitconfig" \
    ".gitignore_global:/state/git/gitignore_global" \
    ".zsh_history:/state/shell/zsh_history" \
    ".bash_history:/state/shell/bash_history"; do
    rel=${entry%%:*}
    legacy_target=${entry#*:}
    if [ -L "$HOME/$rel" ]; then
      actual=$(readlink "$HOME/$rel")
      test "$actual" != "$legacy_target" || {
        echo "verify: $HOME/$rel is still legacy symlink to $actual" >&2
        exit 1
      }
    fi
  done
'
"${COMPOSE[@]}" exec -T sandbox sh -lc '
  set -e
  for path in \
    /state/entrypoints \
    /state/claude \
    /state/claude.json \
    /state/codex \
    /state/memsearch \
    /state/git \
    /state/ssh \
    /state/legacy-archive \
    /state/shell/zsh_history \
    /state/shell/bash_history; do
    ! test -e "$path" || {
      echo "verify: legacy state path still active: $path" >&2
      exit 1
    }
  done
'

# XDG config stays in persistent home. XDG cache goes to tmpfs /cache, while
# XDG data/state go to /state so runtime/home stays clean without symlinks.
"${COMPOSE[@]}" exec -T sandbox sh -lc '
  config=${XDG_CONFIG_HOME:-$HOME/.config}
  cache=${XDG_CACHE_HOME:-}
  data=${XDG_DATA_HOME:-}
  state=${XDG_STATE_HOME:-}
  case "$config" in /home/node/*|"$HOME"/*) ;; *) echo "config dir outside home: $config" >&2; exit 1;; esac
  test "$cache" = /cache/xdg || { echo "XDG_CACHE_HOME is $cache, want /cache/xdg" >&2; exit 1; }
  test "$data" = /state/xdg/data || { echo "XDG_DATA_HOME is $data, want /state/xdg/data" >&2; exit 1; }
  test "$state" = /state/xdg/state || { echo "XDG_STATE_HOME is $state, want /state/xdg/state" >&2; exit 1; }
  test "${NPM_CONFIG_CACHE:-}" = /cache/npm || { echo "NPM_CONFIG_CACHE is ${NPM_CONFIG_CACHE:-}, want /cache/npm" >&2; exit 1; }
  mkdir -p "$config" "$cache" "$data" "$state" && test -w "$config" && test -w "$cache" && test -w "$data" && test -w "$state"
'

# Git global ignore is seeded and wired to the persistent XDG ignore file.
"${COMPOSE[@]}" exec -T sandbox sh -lc '
  set -e
  ignore="$HOME/.config/git/ignore"
  marker="agent-sandbox-verify.ignore"
  test "$(git config --global --get core.excludesfile)" = "$ignore"
  test -f "$ignore"
  trap "sed -i \"/^$marker\$/d\" \"$ignore\" 2>/dev/null || true" EXIT
  grep -Fxq "$marker" "$ignore" || printf "\n%s\n" "$marker" >> "$ignore"
  rm -rf /tmp/git-ignore-verify
  mkdir -p /tmp/git-ignore-verify
  cd /tmp/git-ignore-verify
  git init -q
  : > "$marker"
  : > keep.txt
  status=$(git status --short --untracked-files=all)
  test "$status" = "?? keep.txt"
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
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q "HISTFILE=/state/shell/history/zsh_history" /home/node/.zshrc'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'grep -q "HISTFILE=/state/shell/history/bash_history" /home/node/.bashrc'
"${COMPOSE[@]}" exec -T sandbox sh -lc 'test -d /state/shell/history'

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

# --- new: agent-sandbox shell/<cli> passthrough -----------------------------
# Inside workspace: map cwd → /workspace/<rel>.
# Outside workspace: fall back to /workspace (warn on stderr, don't refuse).

mkdir -p "$ROOT/runtime/workspaces/verify-passthrough/sub"
out=$( cd "$ROOT/runtime/workspaces/verify-passthrough/sub" \
       && "$ROOT/bin/agent-sandbox" pwd )
test "$out" = "/workspace/verify-passthrough/sub" || {
  echo "verify: passthrough mapped cwd to '$out' (want /workspace/verify-passthrough/sub)" >&2
  exit 1
}
rm -rf "$ROOT/runtime/workspaces/verify-passthrough"

out=$( cd /tmp && "$ROOT/bin/agent-sandbox" pwd 2>/dev/null )
test "$out" = "/workspace" || {
  echo "verify: passthrough from /tmp should fall back to /workspace, got '$out'" >&2
  exit 1
}

# --- new: --self overlay --------------------------------------------------
# Tear down the current stack and re-up with --self pointing at this repo.
# cleanup trap will down the stack at the end either way.
"${COMPOSE[@]}" down >/dev/null
export AGENT_SANDBOX_SELF_DIR="$ROOT"
"$ROOT/bin/agent-sandbox" up --self

# /self is now mounted; cwd at $ROOT maps to /self
out=$( cd "$ROOT" && "$ROOT/bin/agent-sandbox" pwd )
test "$out" = "/self" || {
  echo "verify: with --self, cwd at repo root should map to /self, got '$out'" >&2
  exit 1
}

# Subdir under self_dir maps to /self/<rel>
out=$( cd "$ROOT/sandbox" && "$ROOT/bin/agent-sandbox" pwd )
test "$out" = "/self/sandbox" || {
  echo "verify: with --self, cwd at \$ROOT/sandbox should map to /self/sandbox, got '$out'" >&2
  exit 1
}

# cwd outside both workspace and self still falls back to /workspace
out=$( cd /tmp && "$ROOT/bin/agent-sandbox" pwd 2>/dev/null )
test "$out" = "/workspace" || {
  echo "verify: with --self, cwd /tmp should still fall back to /workspace, got '$out'" >&2
  exit 1
}

echo "verify: ok"
