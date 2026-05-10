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

# Keep passwordless sudo opt-in. The sandbox runs as the unprivileged node user
# by default; enabling sudo is useful for trusted dev sessions but weakens the
# container boundary for agent-driven commands.
ARG ENABLE_PASSWORDLESS_SUDO=0
RUN if [ "$ENABLE_PASSWORDLESS_SUDO" = "1" ]; then \
        echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node \
        && chmod 0440 /etc/sudoers.d/node; \
    fi \
    && chsh -s /bin/zsh node

# Image-baked npm global prefix used at build time for bundled CLIs (codex).
# Runtime NPM_CONFIG_PREFIX points at /tool-bin/user/npm-global so user/agent
# `npm i -g` installs persist without rebuilding the image.
RUN mkdir -p /usr/local/share/npm-global \
    && mkdir -p /cache/npm \
    && chown -R node:node /usr/local/share/npm-global /cache

ENV TZ=America/Los_Angeles
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    EDITOR=vim \
    SHELL=/bin/zsh \
    NPM_CONFIG_PREFIX=/tool-bin/user/npm-global \
    NPM_CONFIG_CACHE=/cache/npm \
    AGENT_SANDBOX_RUNTIME=/state \
    AGENT_SANDBOX_TOOL_BIN=/tool-bin \
    XDG_RUNTIME_DIR=/tmp/xdg-runtime \
    PATH=/tool-bin/user/bin:/tool-bin/user/npm-global/bin:/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin

# nix-portable: a single static binary that gives the agent a working `nix`
# without root, daemon, or system-wide install. Lets users install ffmpeg /
# imagemagick / etc. from nixpkgs without rebuilding the image. The store
# lives under ~/.nix-portable, which the entrypoint redirects to
# /state/dev-cache/nix-portable via the home-ephemeral list.
ARG TARGETARCH
ARG NIX_PORTABLE_VERSION=v012.0
RUN case "${TARGETARCH:-amd64}" in \
        amd64)  np_arch=x86_64 ;; \
        arm64)  np_arch=aarch64 ;; \
        *)      echo "nix-portable: unsupported arch ${TARGETARCH}"; exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/nix-portable \
        "https://github.com/DavHau/nix-portable/releases/download/${NIX_PORTABLE_VERSION}/nix-portable-${np_arch}" \
    && chmod 0755 /usr/local/bin/nix-portable

# BuildKit's COPY --chmod applies the file mode to implicitly created parent
# directories too, which strips execute (search) bits and silently breaks
# non-root reads of files under /etc/agent-sandbox. Create the dir explicitly.
RUN install -d -m 0755 /etc/agent-sandbox

COPY --chmod=755 files/entrypoint /usr/local/bin/sandbox-entrypoint
COPY --chmod=755 files/install-claude /usr/local/bin/install-claude
COPY --chmod=755 files/claude /usr/local/bin/claude
COPY --chmod=644 files/zshrc /etc/agent-sandbox/zshrc
COPY --chmod=644 files/env-loader.sh /etc/agent-sandbox/env-loader.sh
COPY --chmod=644 files/home-ephemeral.list /etc/agent-sandbox/home-ephemeral.list

WORKDIR /workspace
USER node

# Codex CLI (still distributed via npm). Installed at build time into the
# image-baked npm prefix so it ships with the image; runtime NPM_CONFIG_PREFIX
# is overridden to /tool-bin/user/npm-global for user/agent installs.
RUN NPM_CONFIG_PREFIX=/usr/local/share/npm-global npm install -g @openai/codex

ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
CMD ["zsh", "-i"]
