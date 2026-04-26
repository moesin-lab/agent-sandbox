FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    zsh jq curl procps ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY files/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY files/watchdog.sh /usr/local/bin/watchdog.sh
COPY files/mcp-start.sh /usr/local/bin/mcp-start.sh
COPY files/shellrc.zsh /home/node/.zshrc

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/watchdog.sh /usr/local/bin/mcp-start.sh \
    && chown -R node:node /home/node

USER node
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh", "-i"]
