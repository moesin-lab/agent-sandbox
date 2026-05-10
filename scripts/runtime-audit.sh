#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/runtime"

section() {
  printf '\n== %s ==\n' "$1"
}

size_of() {
  local path=$1
  if [[ -e "$path" || -L "$path" ]]; then
    du -sh "$path" 2>/dev/null | awk '{print $1 "\t" $2}'
  fi
}

list_existing() {
  local path
  for path in "$@"; do
    if [[ -e "$path" || -L "$path" ]]; then
      printf '%s\n' "${path#"$ROOT/"}"
    fi
  done
}

list_dir_entries() {
  local dir=$1
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 ! -name .gitkeep -print | sort |
    sed "s#^$ROOT/##"
}

list_executables() {
  local dir=$1
  local file
  [[ -d "$dir" ]] || return 0
  while IFS= read -r file; do
    [[ -x "$file" ]] || continue
    printf '%s\n' "${file#"$ROOT/"}"
  done < <(find "$dir" -type f -print | sort)
}

section "Runtime Size"
size_of "$RUNTIME"
for path in "$RUNTIME"/workspaces "$RUNTIME"/home "$RUNTIME"/state "$RUNTIME"/logs "$RUNTIME"/tool-bin; do
  size_of "$path"
done

section "Git Visibility"
git -C "$ROOT" status --short --ignored runtime | sed -n '1,120p'

section "Persisted Home Entrypoints"
list_existing \
  "$RUNTIME/home/.gitconfig" \
  "$RUNTIME/home/.ssh" \
  "$RUNTIME/home/.mails/config.json" \
  "$RUNTIME/home/.claude/hooks" \
  "$RUNTIME/home/.claude/commands" \
  "$RUNTIME/home/.claude/skills" \
  "$RUNTIME/home/.claude/agents" \
  "$RUNTIME/home/.claude/bin" \
  "$RUNTIME/home/.claude/scripts" \
  "$RUNTIME/home/.claude/statusline-command.sh" \
  "$RUNTIME/home/.codex/config.toml" \
  "$RUNTIME/home/.codex/auth.json" \
  "$RUNTIME/home/.codex/plugins" \
  "$RUNTIME/home/.codex/rules" \
  "$RUNTIME/home/.codex/skills"

section "State Entrypoints"
list_existing \
  "$RUNTIME/state/env.local" \
  "$RUNTIME/state/home-ephemeral.local" \
  "$RUNTIME/state/shell/zshenv.local" \
  "$RUNTIME/state/shell/zshrc.local" \
  "$RUNTIME/state/shell/profile.local" \
  "$RUNTIME/state/shell/bashrc.local"

section "State Sentinels And Notes"
list_existing \
  "$RUNTIME/state/compose-mode" \
  "$RUNTIME/state/compose-self"
list_dir_entries "$RUNTIME/state/host-communication"

section "Tool Binaries"
printf '%s\n' '-- managed wrapper targets --'
list_dir_entries "$RUNTIME/tool-bin/managed"
printf '%s\n' '-- user PATH executables --'
list_executables "$RUNTIME/tool-bin/user"

section "Symlinks"
find "$RUNTIME" -type l -print | sort | while IFS= read -r link; do
  target=$(readlink "$link" 2>/dev/null || true)
  printf '%s -> %s\n' "${link#"$ROOT/"}" "$target"
done

section "Large Runtime Entries"
find "$RUNTIME" -mindepth 1 -maxdepth 3 -print0 |
  xargs -0 du -sh 2>/dev/null |
  sort -h |
  tail -30 |
  sed "s#	$ROOT/#	#"

section "Cleanup Candidates"
for path in \
  "$RUNTIME/logs" \
  "$RUNTIME/home/.cache" \
  "$RUNTIME/home/.claude/cache" \
  "$RUNTIME/home/.codex/cache" \
  "$RUNTIME/home/.codex/.tmp" \
  "$RUNTIME/home/.codex/tmp" \
  "$RUNTIME/home/.codex/shell_snapshots" \
  "$RUNTIME/state/dev-cache"; do
  size_of "$path"
done

printf '\nAudit is read-only. Review paths before removing anything under runtime/.\n'
