# 架构说明

## 概览

仓库提供一个固定的三服务拓扑：`sandbox`、`proxy`、`mcp-gateway`。顶层入口 `bin/agent-sandbox` 直接调用仓库根的 `compose.yaml`，没有 profile 切换、没有可拼装的 compose 片段。

镜像名、compose 项目名等覆盖项已经在 `compose.yaml` 里通过 `${VAR:-default}` 给出默认值；需要覆盖时在仓库根放一个 `.env`，Docker compose 会自动加载。

## 组件

### `sandbox/`

Agent 的交互式运行环境。挂载点：

- `runtime/workspaces` → `/workspace`（项目代码）
- `runtime/home` → `/home/node`（持久化用户家目录，包含 oauth 凭据、shell 历史、`~/.local/bin`）
- `runtime/logs` → `/runtime/logs`
- `runtime/state` → `/runtime/state`

镜像内预装的 Agent CLI：

- `claude`：build 时按 `manifest.json` 校验 SHA256 后下载到 `/opt/claude/claude`（不在 PATH）。容器入口 `sandbox-entrypoint` 在每次启动时检查，如果 `$HOME/.local/bin/claude` 不存在就 seed 一份过去——这样 claude 落在上游约定位置 `~/.local/bin`，由 `runtime/home` 卷持久化，self-update 写回原位置；镜像层不污染 PATH，运行时也不需要联网。
- `codex`：通过 `npm install -g @openai/codex` 装在 `/usr/local/share/npm-global/bin`（`NPM_CONFIG_PREFIX` 控制路径），镜像层即可用。

API 凭据通过 host 环境变量透传，参考 `compose.yaml` 的 `sandbox.environment`：

- `ANTHROPIC_API_KEY`、`OPENAI_API_KEY` 以无 `=` 形式列出，未设置则不进容器
- 没设也无所谓，CLI 会走 oauth 流程，凭据落在 `runtime/home` 卷里复用

镜像里还预装 zsh + starship + 常用工具（git/curl/vim/ripgrep/fzf/jq/sudo/locale）；node 用户有 NOPASSWD sudo。容器入口除了 seed claude 二进制之外不做任何额外事情。

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

### `compose.yaml`

仓库根的 `compose.yaml` 声明三个稳定服务和两条网络：

- `agent_net`（internal=true）：sandbox / proxy / mcp-gateway 内部互通
- `egress_net`：proxy 和 mcp-gateway 用来对外联网；sandbox 不直接挂

sandbox 服务没有自己的 `networks` 块，因为 `network_mode: "service:proxy"` 已经把它绑到 proxy 的 netns 上。

## 运行流程

1. `bin/agent-sandbox up` 调用 `docker compose -f compose.yaml up -d`，三个容器并行起来（sandbox `depends_on` proxy 与 mcp-gateway）。
2. proxy 启动脚本生成自签 cert、初始化 ssl_db、装好 iptables NAT 规则、exec 到 squid。
3. sandbox 容器入口 seed 一次 claude 二进制，然后 exec 到 zsh（或 compose 指定的命令）。
4. sandbox 内 80/443 流量被 proxy 容器的 iptables 透明重定向到 squid；其它端口（含 mcp-gateway:8080）直连。
5. MCP 工具调用走 `MCP_GITHUB_URL` 指向的 named server 路径，进 mcp-gateway 后由 mcp-proxy 转 stdio。

## 当前范围

刻意停留在 starter kit：单一固定拓扑、单一默认运行模式。新增 MCP 走"扩 mcp-gateway 镜像 + 加 named server"路径，不膨胀 compose 服务图。隔离强度由 `blocklist.txt` 覆盖度决定，需要更严的场景应改为 default-deny 并扩 allowlist。
