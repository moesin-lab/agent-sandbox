#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_profile() {
  local root profile
  root="$(project_root)"
  profile="${1:-}"
  load_env_file "$root/config/defaults.env"
  load_env_file "$root/config/profiles/${profile}.env"
}
