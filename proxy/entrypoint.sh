#!/usr/bin/env bash
set -euo pipefail

CERT_DIR=/etc/squid/ssl
SSL_DB=/var/cache/squid/ssl_db

# Self-signed cert for ssl-bump's peek phase. We never present this to clients
# (splice = TCP passthrough), so it does not need to be trusted anywhere.
mkdir -p "$CERT_DIR"
if [[ ! -f "$CERT_DIR/bump.pem" ]]; then
  openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/CN=agent-sandbox-bump" \
    -keyout "$CERT_DIR/bump.pem" \
    -out    "$CERT_DIR/bump.pem" 2>/dev/null
  chown proxy:proxy "$CERT_DIR/bump.pem"
fi

# security_file_certgen needs an initialized state dir even when we only splice.
if [[ ! -d "$SSL_DB" ]]; then
  /usr/lib/squid/security_file_certgen -c -s "$SSL_DB" -M 4MB
  chown -R proxy:proxy "$SSL_DB"
fi

cp /rules/blocklist.txt /etc/squid/blocklist.txt

# Transparent NAT: redirect outbound 80/443 from non-squid uids to local squid.
# The sandbox container shares this netns via `network_mode: "service:proxy"`,
# so its packets enter the OUTPUT chain in this container.
iptables -t nat -F OUTPUT
iptables -t nat -A OUTPUT -p tcp --dport 80  -m owner ! --uid-owner proxy -j REDIRECT --to-ports 3128
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner ! --uid-owner proxy -j REDIRECT --to-ports 3129

exec squid -N -f /etc/squid/squid.conf
