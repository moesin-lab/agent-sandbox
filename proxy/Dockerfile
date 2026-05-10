FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        squid-openssl \
        iptables \
        openssl \
        ca-certificates \
        tzdata \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=America/Los_Angeles
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

COPY squid.conf /etc/squid/squid.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health: NAT redirect chain installed AND both squid intercept ports listening.
# Anything less means transparent intercept is incomplete and the sandbox can
# leak unfiltered traffic on container start. retries=5 → unhealthy after ~10s.
HEALTHCHECK --interval=2s --timeout=2s --retries=5 --start-period=5s \
    CMD sh -c 'iptables -t nat -C OUTPUT -j AGENT_SANDBOX_REDIRECT 2>/dev/null \
        && nc -z 127.0.0.1 3128 \
        && nc -z 127.0.0.1 3129'

ENTRYPOINT ["/entrypoint.sh"]
