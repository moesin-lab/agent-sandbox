#!/usr/bin/env bash
set -euo pipefail

project_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

load_env_file() {
  local file="$1"
  if [[ ! -r "$file" ]]; then
    printf 'load_env_file: cannot read env file: %s\n' "$file" >&2
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}
