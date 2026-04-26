FROM ghcr.io/github/github-mcp-server:latest AS github-mcp-server

FROM ghcr.io/sparfenyuk/mcp-proxy:latest

COPY --from=github-mcp-server /server/github-mcp-server /usr/local/bin/github-mcp-server

ENTRYPOINT ["catatonit", "--", "mcp-proxy"]
CMD [
  "--host=0.0.0.0",
  "--port=8080",
  "--pass-environment",
  "--named-server-config",
  "/etc/mcp-gateway/servers.json"
]
