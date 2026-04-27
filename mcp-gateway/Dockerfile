FROM ghcr.io/github/github-mcp-server:latest AS github-mcp-server

FROM ghcr.io/sparfenyuk/mcp-proxy:latest

COPY --from=github-mcp-server /server/github-mcp-server /usr/local/bin/github-mcp-server

ENV TZ=America/Los_Angeles
# /usr/share/zoneinfo may or may not exist depending on the upstream base image;
# fall back gracefully so the build never fails on the symlink step.
RUN if [ -f "/usr/share/zoneinfo/$TZ" ]; then \
        ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone; \
    fi

ENTRYPOINT ["catatonit", "--", "mcp-proxy"]
CMD [
  "--host=0.0.0.0",
  "--port=8080",
  "--pass-environment",
  "--named-server-config",
  "/etc/mcp-gateway/servers.json"
]
