FROM ghcr.io/github/github-mcp-server:latest AS github-mcp-server

# Static busybox binary as a healthcheck probe — keeps us from apt-installing
# anything into the upstream mcp-proxy image (which may be distroless/minimal).
FROM busybox:1.37.0-musl AS healthbin

FROM ghcr.io/sparfenyuk/mcp-proxy:latest

COPY --from=github-mcp-server /server/github-mcp-server /usr/local/bin/github-mcp-server
COPY --from=healthbin /bin/wget /usr/local/bin/hc-wget

ENV TZ=America/Los_Angeles
# /usr/share/zoneinfo may or may not exist depending on the upstream base image;
# fall back gracefully so the build never fails on the symlink step.
RUN if [ -f "/usr/share/zoneinfo/$TZ" ]; then \
        ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone; \
    fi

HEALTHCHECK --interval=2s --timeout=2s --retries=5 --start-period=5s \
    CMD ["/usr/local/bin/hc-wget", "-q", "-O", "-", "http://127.0.0.1:8080/status"]

ENTRYPOINT ["catatonit", "--", "mcp-proxy"]
CMD ["--host=0.0.0.0", "--port=8080", "--pass-environment", "--named-server-config", "/etc/mcp-gateway/servers.json"]
