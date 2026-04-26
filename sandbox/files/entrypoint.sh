#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p /runtime/logs /runtime/state /workspace
nohup /usr/local/bin/watchdog.sh >> /runtime/logs/watchdog.log 2>&1 &
"$script_dir/mcp-start.sh"

exec "$@"
