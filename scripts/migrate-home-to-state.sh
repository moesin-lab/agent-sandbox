#!/usr/bin/env bash
# DEPRECATED: this script migrated runtime/home → runtime/state in the layout
# where /home/node was tmpfs. The current architecture goes the other direction
# (state → home) and is handled automatically by sandbox entrypoint at first
# boot, so this script is no longer needed. Kept for reference; will be removed.
set -euo pipefail

echo "WARN: scripts/migrate-home-to-state.sh is deprecated; the entrypoint now" >&2
echo "      auto-migrates legacy /state/{claude,codex,xdg,...} into runtime/home." >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/runtime/home}"
STATE="${AGENT_SANDBOX_STATE_DIR:-$ROOT/runtime/state}"
TOOL_BIN="${AGENT_SANDBOX_TOOL_BIN_DIR:-$ROOT/runtime/tool-bin}"

if [[ ! -d "$SRC" ]]; then
  printf 'migrate-home-to-state: source home not found: %s\n' "$SRC" >&2
  exit 1
fi

mkdir -p \
  "$STATE/claude" \
  "$STATE/codex" \
  "$STATE/entrypoints/claude" \
  "$STATE/git" \
  "$STATE/memsearch" \
  "$STATE/ssh" \
  "$STATE/xdg/config" \
  "$STATE/xdg/data" \
  "$STATE/xdg/state" \
  "$TOOL_BIN"

copy_file() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  cp -p "$src" "$dst"
}

copy_dir() {
  local src="$1" dst="$2"
  shift 2
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"
  rsync -a "$@" "$src/" "$dst/"
}

link_entry_dir() {
  local name="$1"
  local link="$STATE/claude/$name"
  mkdir -p "$STATE/entrypoints/claude/$name"
  rm -rf "$link"
  ln -s "../entrypoints/claude/$name" "$link"
}

copy_dir "$SRC/.claude" "$STATE/claude" \
  --exclude '/cache' \
  --exclude '/plugins/cache' \
  --exclude '/docker-sandbox' \
  --exclude '/.pytest_cache'

rm -rf "$STATE/claude/cache"
ln -s "/cache/claude" "$STATE/claude/cache"

for name in agents bin commands hooks scripts skills; do
  if [[ -d "$SRC/.claude/$name" ]]; then
    copy_dir "$SRC/.claude/$name" "$STATE/entrypoints/claude/$name"
  fi
  link_entry_dir "$name"
done

for file in statusline-command.sh statusline-command.sh.bak statusline-command.sh.wrap; do
  copy_file "$SRC/.claude/$file" "$STATE/entrypoints/claude/$file"
done
rm -f "$STATE/claude/statusline-command.sh"
ln -s "../entrypoints/claude/statusline-command.sh" "$STATE/claude/statusline-command.sh"

copy_file "$SRC/.claude.json" "$STATE/claude.json"
copy_dir "$SRC/.codex" "$STATE/codex" \
  --exclude '/.tmp' \
  --exclude '/tmp' \
  --exclude '/cache'

copy_file "$SRC/.gitconfig" "$STATE/git/gitconfig"
copy_file "$SRC/.gitignore_global" "$STATE/git/gitignore_global"
copy_file "$SRC/.ssh/known_hosts" "$STATE/ssh/known_hosts"
copy_dir "$SRC/.memsearch" "$STATE/memsearch"

copy_file "$SRC/.config/starship.toml" "$STATE/xdg/config/starship.toml"
copy_dir "$SRC/.config/git" "$STATE/xdg/config/git"
copy_dir "$SRC/.config/uv" "$STATE/xdg/config/uv"

printf 'migrate-home-to-state: migrated selected state from %s\n' "$SRC"
printf '  state:    %s\n' "$STATE"
printf '  cache:    skipped (container /cache is tmpfs and disposable)\n'
printf '  tool-bin: %s (not populated automatically; runtime tools reinstall through image wrappers)\n' "$TOOL_BIN"
