# 架构说明

## 概览

仓库提供两套启动拓扑：

- 默认模式：`sandbox`、`proxy`、`mcp-gateway`
- 简洁模式：`sandbox`、`proxy`

顶层入口 `bin/agent-sandbox` 负责在 `compose.yaml` 和 `compose.simple.yaml` 之间切换；最近一次启动模式会写入 `runtime/state/compose-mode`，供 `shell` / `logs` / `down` 复用。`bin/sandbox` 是它的短入口，专门用于直接进入容器终端。

镜像名、compose 项目名等覆盖项已经在 `compose.yaml` 里通过 `${VAR:-default}` 给出默认值；需要覆盖时在仓库根放一个 `.env`，Docker compose 会自动加载。

## 组件

### `sandbox/`

Agent 的交互式运行环境。挂载点：

- `runtime/workspaces` → `/workspace`（项目代码）
- `runtime/state` → `/state`（oauth、session、sqlite、小数据库、普通配置）
- `runtime/logs` → `/logs`
- `runtime/tool-bin` → `/tool-bin`（持久化可执行物：`managed/` wrapper 下载、不在 PATH；`user/` 用户/agent 安装、**在** PATH）
- tmpfs → `/cache`（可重建缓存，重启即丢）

`/home/node` 是 tmpfs，不再作为整体持久化单元。容器入口每次启动时在 home 中生成 symlink 视图：

- 规矩应用通过 `XDG_CONFIG_HOME=/state/xdg/config`、`XDG_DATA_HOME=/state/xdg/data`、`XDG_STATE_HOME=/state/xdg/state`、`XDG_CACHE_HOME=/cache/xdg` 收口
- 常见 home 子路径如 `~/.config`、`~/.cache`、`~/.local/share`、`~/.local/state` 被 symlink 到对应 XDG 根
- `~/.claude`、`~/.codex`、`~/.ssh`、`~/.gitconfig` 等兼容路径指向 `/state` 下的稳定位置
- shell rc/profile 骨架由镜像层每次生成，末尾 source `/state/shell/*.local` 作为持久化扩展点

镜像内预装的 Agent CLI：

- `claude`：镜像层提供 `/usr/local/bin/claude` wrapper。首次执行时 wrapper 调用 `/usr/local/bin/install-claude`，在线下载并按官方 `manifest.json` 校验 SHA256，然后写入 `/tool-bin/managed/claude`。`/tool-bin/managed/` 不在默认 `PATH` 中，后续执行仍通过镜像层 wrapper 进入；需要 pin 版本时可设置 `CLAUDE_RELEASE_TAG`。
- `codex`：构建时以 `NPM_CONFIG_PREFIX=/usr/local/share/npm-global` 装在镜像层 `/usr/local/share/npm-global/bin`，镜像层即可用。运行时 `NPM_CONFIG_PREFIX` 被改为 `/tool-bin/user/npm-global`，这样容器内 `npm i -g <pkg>` 会写到持久化目录并自动进 PATH。

API 凭据通过 host 环境变量透传，参考 `compose.yaml` 的 `sandbox.environment`：

- `ANTHROPIC_API_KEY`、`OPENAI_API_KEY` 以无 `=` 形式列出，未设置则不进容器
- 没设也无所谓，CLI 会走 oauth 流程，凭据落在 `/state` 对应目录里复用

镜像里还预装 zsh + starship + 常用工具（git/curl/vim/ripgrep/fzf/jq/sudo/locale）。passwordless sudo 默认关闭。容器根文件系统默认只读，只有 `/workspace`、`/state`、`/cache`、`/logs`、`/tool-bin` 和 tmpfs 目录可写。

### `proxy/`

基于 `debian:bookworm-slim` 的 Squid（`squid-openssl`）容器，工作在透明拦截模式：

- `sandbox` 通过 `network_mode: "service:proxy"` 共享本容器的 network namespace
- 启动脚本在 `nat OUTPUT` 链添加两条 `REDIRECT` 规则，把非 `proxy` uid 的 80/443 流量重定向到本地 squid 的 3128 / 3129，按 uid 把 squid 自身豁免出去
- 默认放行：未在 `blocklist.txt` 中显式列出的目的全部直通
- HTTP 走 `http_port 3128 intercept`，命中 blocklist 的 `dstdomain` 直接 `http_access deny`
- HTTPS 走 `https_port 3129 intercept ssl-bump`，在 `SslBump1` peek 到 SNI 后，命中 blocklist 直接 terminate；未命中的 splice 直通，不解密、不需要客户端装 CA
- 自签 cert 仅用于 ssl-bump 内部 peek 阶段元数据，不会展示给客户端

应用感知不到代理存在，sandbox 内没有 `HTTP_PROXY` / `HTTPS_PROXY`。

### `mcp-gateway/`

MCP 平面的统一入口。镜像里聚合：

- `mcp-proxy`（来自 `ghcr.io/sparfenyuk/mcp-proxy`）做 stdio→HTTP 协议桥接和路径分发
- 官方 `github-mcp-server` stdio 二进制（来自 `ghcr.io/github/github-mcp-server`）

`config/mcp-gateway/servers.json` 决定 named server 名字到启动命令的映射。当前唯一一项 `github`，对外路径 `http://mcp-gateway:8080/servers/github/mcp`。GitHub PAT 通过 compose 只注入这个容器，`mcp-proxy` 透传环境给 `github-mcp-server`，sandbox 自己不持有 PAT。

mcp-gateway 不参与透明代理链路，端口 8080 不在 NAT 规则里，sandbox 通过容器名直连。

### `compose.yaml` 与 `compose.simple.yaml`

仓库根有两份 compose 文件，共用相同的服务定义风格和网络模型：

- `compose.yaml`：默认模式，包含 `sandbox` / `proxy` / `mcp-gateway`
- `compose.simple.yaml`：简洁模式，只包含 `sandbox` / `proxy`
- `agent_net`（internal=true）：内部互通网络
- `egress_net`：`proxy` 与默认模式下的 `mcp-gateway` 对外联网；sandbox 不直接挂

sandbox 服务没有自己的 `networks` 块，因为 `network_mode: "service:proxy"` 已经把它绑到 proxy 的 netns 上。

## 运行流程

1. `bin/agent-sandbox up` 启动默认模式；`bin/agent-sandbox up simple` 启动简洁模式。
2. proxy 启动脚本生成自签 cert、初始化 ssl_db、装好 iptables NAT 规则、exec 到 squid。
3. sandbox 容器入口在 tmpfs home 中生成 XDG/symlink 视图、`/tool-bin/managed/` 与 `/tool-bin/user/{bin,npm-global/bin}` 子目录、以及默认 shell 启动骨架（末尾 source `/state/shell/*.local`），然后 exec 到 zsh（或 compose 指定的命令）。
4. sandbox 内 80/443 流量被 proxy 容器的 iptables 透明重定向到 squid；默认模式下，其它端口（含 mcp-gateway:8080）直连。
5. 只有默认模式会注入 `MCP_GITHUB_URL`，MCP 工具调用再经 `mcp-gateway` 由 `mcp-proxy` 转 stdio。

## 当前范围

当前仍刻意停留在 starter kit：只保留默认模式和一个不带 MCP 的简洁模式，不再引入更细粒度的 compose 拼装。新增 MCP 走"扩 mcp-gateway 镜像 + 加 named server"路径。隔离强度由 `blocklist.txt` 覆盖度决定，需要更严的场景应改为 default-deny 并扩 allowlist。
