#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_profile() {
  local root profile
  root="$(project_root)"
  load_env_file "$root/config/defaults.env"
  profile="${1:-${DEFAULT_PROFILE:-}}"
  if [[ -z "$profile" ]]; then
    printf 'load_profile: DEFAULT_PROFILE is not set\n' >&2
    return 1
  fi

  if [[ ! -e "$root/config/profiles/${profile}.env" ]]; then
    printf 'load_profile: profile env file not found: %s\n' "$root/config/profiles/${profile}.env" >&2
    return 1
  fi
  load_env_file "$root/config/profiles/${profile}.env"
}
