#!/usr/bin/env bash
set -euo pipefail

mkdir -p /runtime/logs /runtime/state /workspace
nohup /usr/local/bin/watchdog.sh >> /runtime/logs/watchdog.log 2>&1 &
exec "$@"
