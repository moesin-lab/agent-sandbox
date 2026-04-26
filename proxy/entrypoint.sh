#!/usr/bin/env bash
set -euo pipefail

cp /rules/blocklist.txt /etc/squid/blocklist.txt
exec squid -N -f /etc/squid/squid.conf
