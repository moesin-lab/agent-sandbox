#!/usr/bin/env bash
set -euo pipefail

project_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

load_env_file() {
  local file="$1"
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}
