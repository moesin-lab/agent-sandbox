FROM ghcr.io/github/github-mcp-server:latest AS github-mcp-server

FROM ghcr.io/sparfenyuk/mcp-proxy:latest

COPY --from=github-mcp-server /server/github-mcp-server /usr/local/bin/github-mcp-server

ENV TZ=America/Los_Angeles
# /usr/share/zoneinfo may or may not exist depending on the upstream base image;
# fall back gracefully so the build never fails on the symlink step.
RUN if [ -f "/usr/share/zoneinfo/$TZ" ]; then \
        ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone; \
    fi

# Probe the listening socket rather than an HTTP route — mcp-proxy doesn't
# guarantee any specific path is non-5xx in every release. Use the python
# already shipped with mcp-proxy so we don't have to ship extra binaries
# (busybox multi-call / wget can't be COPYed under a different name).
# The business-level reachability check still lives in scripts/verify.sh.
HEALTHCHECK --interval=2s --timeout=2s --retries=5 --start-period=5s \
    CMD ["python3", "-c", "import socket,sys; s=socket.socket(); s.settimeout(1); s.connect(('127.0.0.1', 8080)); s.close()"]

ENTRYPOINT ["catatonit", "--", "mcp-proxy"]
CMD ["--host=0.0.0.0", "--port=8080", "--pass-environment", "--named-server-config", "/etc/mcp-gateway/servers.json"]
