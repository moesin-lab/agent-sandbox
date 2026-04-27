FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        zsh \
        git \
        curl \
        vim \
        less \
        ripgrep \
        fzf \
        jq \
        sudo \
        ca-certificates \
        procps \
        locales \
    && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin

# Passwordless sudo for the existing node user; default shell zsh.
RUN echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node \
    && chsh -s /bin/zsh node

# npm global prefix that the node user can write to.
RUN mkdir -p /usr/local/share/npm-global \
    && chown -R node:node /usr/local/share/npm-global

ENV TZ=America/Los_Angeles
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    EDITOR=vim \
    SHELL=/bin/zsh \
    NPM_CONFIG_PREFIX=/usr/local/share/npm-global \
    AGENT_SANDBOX_RUNTIME=/runtime \
    PATH=/workspace/bin:/usr/local/share/npm-global/bin:/home/node/.local/bin:$PATH

# Claude Code: download the verified native binary into /opt/claude. The
# entrypoint seeds it into $HOME/.local/bin on first start so the binary
# ends up at the location the official installer would have used. To pin a
# version, replace `latest` below with a release tag.
ARG TARGETARCH
RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
        amd64) plat=linux-x64 ;; \
        arm64) plat=linux-arm64 ;; \
        *) echo "unsupported arch: $arch"; exit 1 ;; \
    esac; \
    base="https://downloads.claude.ai/claude-code-releases"; \
    version="$(curl -fsSL "$base/latest")"; \
    expected="$(curl -fsSL "$base/$version/manifest.json" | jq -r ".platforms[\"$plat\"].checksum")"; \
    mkdir -p /opt/claude; \
    curl -fsSL "$base/$version/$plat/claude" -o /opt/claude/claude; \
    echo "$expected  /opt/claude/claude" | sha256sum -c -; \
    chmod +x /opt/claude/claude

COPY --chmod=755 files/entrypoint                    /usr/local/bin/sandbox-entrypoint
COPY --chmod=755 files/git-credential-github-token   /usr/local/bin/git-credential-github-token
COPY            files/gitconfig                      /etc/gitconfig
COPY --chown=node:node files/zshrc                   /home/node/.zshrc

WORKDIR /workspace
USER node

# Codex CLI (still distributed via npm). Installed as the node user so files
# land in NPM_CONFIG_PREFIX with correct ownership.
RUN npm install -g @openai/codex

ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
CMD ["zsh", "-i"]
