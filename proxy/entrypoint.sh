#!/usr/bin/env bash
set -euo pipefail

cp /rules/allowlist.txt /etc/squid/allowlist.txt
cp /rules/blocklist.txt /etc/squid/blocklist.txt
exec squid -N -f /etc/squid/squid.conf
