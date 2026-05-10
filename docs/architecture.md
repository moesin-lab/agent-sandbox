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
- `runtime/home` → `/home/node`（用户 home，bind mount，自然持久化）
- `runtime/state` → `/state`（shell 扩展、env vars、dev-cache 池）
- `runtime/logs` → `/logs`
- `runtime/tool-bin` → `/tool-bin`（持久化可执行物：`managed/` host 管理、不在 PATH；`user/` 用户/agent 安装、**在** PATH）
- tmpfs → `/cache`（可重建缓存，重启即丢）

`/home/node` 是宿主机 bind mount，所以任何 `~/.<tool>` 写入默认就持久化到 host 侧 `runtime/home/.<tool>/`，不需要在 entrypoint 里登记。已知 cache / tmp 子路径会由 compose 作为 tmpfs mount 覆盖到 home 下（例如 `.cache`、`.codex/cache`、`.codex/.tmp`、`.claude/cache`），避免高 churn 文件落进 `runtime/home`，也避免 host 侧出现指向容器内路径的 broken symlink；配置、auth、sessions 仍留在 home。通用 cache 通过 `XDG_CACHE_HOME=/cache/xdg` 和 `NPM_CONFIG_CACHE=/cache/npm` 走 tmpfs，XDG data/state 通过 `XDG_DATA_HOME=/state/xdg/data` 与 `XDG_STATE_HOME=/state/xdg/state` 走 state。如果某个目录需要额外分流，用户可以在 `/state/home-ephemeral.local` 显式配置。

执行链相关：

- shell rc 和 profile 骨架（`.zshrc`、`.zshenv`、`.profile`、`.bashrc`）由镜像层每次启动**强制覆盖**，agent 写进 `~/.zshrc` 的内容不会跨重启存活；自定义只能落 `/state/shell/*.local`
- shell history 通过 `HISTFILE=/state/shell/history/{zsh,bash}_history` 落在 state，不污染 home 主体
- XDG config 仍按默认值落到 home；`XDG_CACHE_HOME=/cache/xdg`、`XDG_DATA_HOME=/state/xdg/data`、`XDG_STATE_HOME=/state/xdg/state` 配合 home 下的 cache tmpfs mount，避免 `~/.cache` 和工具 cache 内容出现在 host-backed home

镜像层的 shell 启动骨架 + 共享脚本集中在 `/etc/agent-sandbox/`：

| 路径 | 作用 |
| --- | --- |
| `/etc/agent-sandbox/zshrc` | entrypoint 每次 `cp` 到 `~/.zshrc` 的骨架（starship init / HISTFILE / alias / 末尾 source `/state/shell/zshrc.local`）|
| `/etc/agent-sandbox/env-loader.sh` | `~/.zshenv` / `~/.profile` / `~/.bashrc` 都 source 它，按白名单解析 `/state/env.local` 注入环境变量 |
| `/etc/agent-sandbox/home-ephemeral.list` | 用户追加分流清单模板；默认 cache/tmp 分流由 compose tmpfs mount 负责 |
| `/usr/local/bin/nix-portable` | nixpkgs 的免 root 入口；store 默认落在 `~/.nix-portable` 并随 home 持久化 |

这条目录由 Dockerfile 显式 `install -d -m 0755` 创建：BuildKit 的 `COPY --chmod=NNN` 在隐式建 parent dir 时会把同一权限值套到目录上（644 → 缺 execute 位 → node 用户读不到里面），显式 mkdir 是为了规避这个坑。改这两份文件需要 rebuild sandbox 镜像（属于"故意只能从镜像层变更"那一类）。

镜像内预装的 Agent CLI：

- `claude`：镜像层只提供 `/usr/local/bin/claude` wrapper。真实二进制由 host 放到 `runtime/tool-bin/managed/claude`，容器内对应 `/tool-bin/managed/claude`；缺失时 wrapper 报错并提示 host 放置文件，不会联网下载。`/tool-bin/managed/` 不在默认 `PATH` 中，后续执行仍通过镜像层 wrapper 进入；如果同时提供 `/tool-bin/managed/claude.sha256`，wrapper 会在执行前校验。
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

### `autoheal`（仅默认拓扑）

`willfarrell/autoheal:1.2.0` sidecar，根据 Docker `Health.Status` 自动 `docker restart` unhealthy 容器。`proxy` 和 `mcp-gateway` 各自在 Dockerfile 里声明了 `HEALTHCHECK`（NAT 链 + 监听端口 / `/status` 探活），并在 compose 层打 `autoheal=true` label，autoheal 只看带这个 label 的容器。autoheal 自身 `network_mode: "none"`，仅持有 `/var/run/docker.sock`，无入站攻击面。简洁拓扑不启用 autoheal——简洁模式只剩 proxy 一个能 unhealthy 的服务，价值不抵 docker socket 暴露。

`bin/agent-sandbox` 的 `wait_for_service` 会在容器声明了 healthcheck 时要求 `Health.Status == healthy` 才视为 ready；没声明 healthcheck 的服务（例如 `sandbox` 的 `sleep infinity`）退回到 `State.Status == running`。

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
3. sandbox 容器入口先清理旧 `/state/{claude,codex,...}` 布局和上一版默认生成的 symlink，再按用户的 `/state/home-ephemeral.local`（如果存在）处理额外分流，预创建 `/cache/*`、`/state/xdg/*` 与 `/tool-bin/{managed,user/...}` 子目录，用镜像版本重写 `~/.zshrc/.zshenv/.profile/.bashrc`，然后 exec 到 zsh（或 compose 指定的命令）。
4. sandbox 内 80/443 流量被 proxy 容器的 iptables 透明重定向到 squid；默认模式下，其它端口（含 mcp-gateway:8080）直连。
5. 只有默认模式会注入 `MCP_GITHUB_URL`，MCP 工具调用再经 `mcp-gateway` 由 `mcp-proxy` 转 stdio。

## 当前范围

当前仍刻意停留在 starter kit：只保留默认模式和一个不带 MCP 的简洁模式，不再引入更细粒度的 compose 拼装。新增 MCP 走"扩 mcp-gateway 镜像 + 加 named server"路径。隔离强度由 `blocklist.txt` 覆盖度决定，需要更严的场景应改为 default-deny 并扩 allowlist。
