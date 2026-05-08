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
- `runtime/home` → `/home/node`（持久化用户家目录，包含 oauth 凭据、shell 历史、`~/.local/bin`）
- `runtime/logs` → `/runtime/logs`
- `runtime/state` → `/runtime/state`

镜像内预装的 Agent CLI：

- `claude`：容器入口在启动时检查 `$HOME/.local/bin/claude`；如果缺失，就运行 `/usr/local/bin/install-claude` 在线下载、按 `manifest.json` 校验 SHA256，然后写入持久化的 `runtime/home/.local/bin`。这样 claude 落在上游约定位置，后续启动直接复用；需要 pin 版本时可设置 `CLAUDE_RELEASE_TAG`。
- `codex`：通过 `npm install -g @openai/codex` 装在 `/usr/local/share/npm-global/bin`（`NPM_CONFIG_PREFIX` 控制路径），镜像层即可用。

API 凭据通过 host 环境变量透传，参考 `compose.yaml` 的 `sandbox.environment`：

- `ANTHROPIC_API_KEY`、`OPENAI_API_KEY` 以无 `=` 形式列出，未设置则不进容器
- 没设也无所谓，CLI 会走 oauth 流程，凭据落在 `runtime/home` 卷里复用

镜像里还预装 zsh + starship + 常用工具（git/curl/vim/ripgrep/fzf/jq/sudo/locale）；node 用户有 NOPASSWD sudo。容器入口只做持久化 home 的首次初始化：自动安装 claude、补默认 `.zshrc`，然后再 exec 到主命令。

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
3. sandbox 容器入口在首次启动时把 `claude` 安装到持久化 home，并补齐默认 `.zshrc`，然后 exec 到 zsh（或 compose 指定的命令）。
4. sandbox 内 80/443 流量被 proxy 容器的 iptables 透明重定向到 squid；默认模式下，其它端口（含 mcp-gateway:8080）直连。
5. 只有默认模式会注入 `MCP_GITHUB_URL`，MCP 工具调用再经 `mcp-gateway` 由 `mcp-proxy` 转 stdio。

## 当前范围

当前仍刻意停留在 starter kit：只保留默认模式和一个不带 MCP 的简洁模式，不再引入更细粒度的 compose 拼装。新增 MCP 走"扩 mcp-gateway 镜像 + 加 named server"路径。隔离强度由 `blocklist.txt` 覆盖度决定，需要更严的场景应改为 default-deny 并扩 allowlist。
