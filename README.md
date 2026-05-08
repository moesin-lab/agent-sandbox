# Agent Containment Starter Kit

面向 macOS + Docker Desktop 的 Agent 沙盒模板：在容器里跑 Claude Code / Codex 等编码 Agent，把它们的网络出口收口到一个透明代理 + 一个 MCP 网关，避免直接拿 shell 撞敏感 API。

## 它要解决什么

- Agent 的普通出网应该有受控出口，但又不能把开发体验搞坏
- 敏感能力（GitHub、未来扩展）应该走显式 MCP 通道，而不是裸 `curl`
- 新增 MCP 服务时不应该每次都改主 compose 拓扑

当前默认实现是三服务拓扑，另带一个不启用 MCP 的简洁模式：

- `sandbox`：Agent 运行舱，内置 `codex`，首次启动自动安装 `claude`
- `proxy`：透明 HTTP/HTTPS 代理（Squid intercept + ssl-bump peek/splice），默认放行 + blocklist 过滤
- `mcp-gateway`：基于 `mcp-proxy` 的 MCP 平面，目前内置 `github-mcp-server`

## 仓库结构

```
compose.yaml             # 默认启动拓扑（proxy + sandbox + mcp-gateway）
compose.simple.yaml      # 简洁模式拓扑（proxy + sandbox）
bin/agent-sandbox        # up / down / shell / logs / doctor
bin/sandbox              # 直接进 sandbox 终端的短入口
sandbox/                 # Agent 容器镜像
proxy/                   # Squid 透明代理镜像
mcp-gateway/             # MCP 网关镜像（mcp-proxy + github-mcp-server）
config/
  mcp-gateway/servers.json   # mcp-proxy 的 named server 配置
  proxy-rules/blocklist.txt  # 代理黑名单
runtime/                 # 宿主机上的运行态目录（workspace / state / cache / logs / tool-bin）
scripts/verify.sh        # 端到端验证脚本
docs/                    # 架构、安全模型、扩展指南、验证说明
```

镜像名、挂载路径、资源限制等覆盖项已经在 `compose.yaml` 里以 `${VAR:-default}` 形式给出默认值，需要覆盖时在仓库根放一个 `.env`，Docker compose 会自动加载。可以从 `.env.example` 开始改。

## 挂载路径

默认挂载：

| Host 路径 | 容器路径 | 用途 |
| --- | --- | --- |
| `./runtime/workspaces` | `/workspace` | 工作目录 |
| `./runtime/state` | `/state` | CLI 登录态、session、sqlite、小数据库、普通配置 |
| `./runtime/logs` | `/logs` | 日志 |
| `./runtime/tool-bin` | `/tool-bin` | 可持久化可执行物：`managed/`（wrapper 下载，不在 PATH）+ `user/`（npm 全局、用户安装的二进制，**在** PATH） |
| tmpfs | `/cache` | 可重建缓存，重启即丢 |

`/home/node` 不再是持久化挂载，而是 tmpfs。容器启动时 entrypoint 会用 XDG 环境变量和 symlink 把常见 home 子路径导向 `/state` 或 `/cache`，每次从镜像生成 shell 启动骨架，并在末尾 source `/state/shell/*.local` 作为持久化扩展点。详见 [`docs/persistence.md`](docs/persistence.md)。

要把工作目录换到别的位置，在 `.env` 里设置：

```env
AGENT_SANDBOX_WORKSPACE_DIR=/Users/stypro/dev/sandbox-work
```

只读挂载工作目录：

```env
AGENT_SANDBOX_WORKSPACE_DIR=/Users/stypro/dev/sandbox-work
AGENT_SANDBOX_WORKSPACE_MODE=ro
```

也可以分别调整所有运行态目录：

```env
AGENT_SANDBOX_WORKSPACE_DIR=/Users/stypro/dev/sandbox-work
AGENT_SANDBOX_STATE_DIR=/Users/stypro/.local/state/agent-sandbox/state
AGENT_SANDBOX_LOGS_DIR=/Users/stypro/.local/state/agent-sandbox/logs
AGENT_SANDBOX_TOOL_BIN_DIR=/Users/stypro/.local/state/agent-sandbox/tool-bin
```

如果只想让容器内看到只读源码，可以额外做一个只读副本或后续在 compose 里把 workspace mount 改成 `:ro`；不要把 `~/.ssh`、`~/.aws`、`~/Library` 或 Docker socket 放进这些路径。

## 默认加固

`sandbox` 默认以 `node` 用户运行，关闭 passwordless sudo，并在 compose 层启用只读根文件系统、`no-new-privileges`、`cap_drop: ALL`、PID/CPU/内存上限。默认资源上限可以通过 `.env` 调整：

```env
SANDBOX_PIDS_LIMIT=512
SANDBOX_MEMORY_LIMIT=8g
SANDBOX_CPUS=4
```

如果是可信开发会话、确实需要在容器内 `sudo apt install`，可以临时打开：

```env
ENABLE_PASSWORDLESS_SUDO=1
AGENT_SANDBOX_NO_NEW_PRIVILEGES=false
```

这会降低 sandbox 强度；跑陌生 repo 或 agent 自动命令时不建议打开。

## 快速开始

宿主机环境里准备好需要透传的凭据，按需导出：

```bash
export GITHUB_PERSONAL_ACCESS_TOKEN=...   # 给 mcp-gateway 用，sandbox 不持有
export ANTHROPIC_API_KEY=...              # 给 sandbox 内的 claude 用，可选
export OPENAI_API_KEY=...                 # 给 sandbox 内的 codex 用，可选
```

`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` 没设也行，CLI 会回退到 oauth 流程；oauth 凭据落在持久化的 `runtime/state` 里，下次启动复用。`claude` 命令由镜像层 wrapper 提供，运行时二进制下载到 `runtime/tool-bin/managed/`；该子目录不在默认 `PATH` 中，要 pin 版本可以在启动前设置 `CLAUDE_RELEASE_TAG`。如果在容器里直接 `npm i -g <pkg>`，会装到 `runtime/tool-bin/user/npm-global/`，**在** PATH，重启后保留。

启动默认模式：

```bash
bin/agent-sandbox doctor   # 静态检查依赖和目录
bin/agent-sandbox up       # docker compose up -d
bin/sandbox                # 自动启动并进入 sandbox 容器
```

如果暂时不需要网关和 MCP，启动简洁模式：

```bash
bin/agent-sandbox up simple
bin/sandbox                # 自动沿用最近一次启动模式；没启动会先拉起
```

如果要显式进入简洁模式对应的容器终端，也可以直接跑 `bin/sandbox simple`。`bin/agent-sandbox shell` 现在也会在容器未启动时自动先执行对应模式的 `up`。

停止：`bin/agent-sandbox down`。看日志：`bin/agent-sandbox logs`。也可以显式指定模式，例如 `bin/agent-sandbox down simple`。

## 网络模型

`sandbox` 通过 `network_mode: "service:proxy"` 共享 `proxy` 容器的 network namespace，所以它**没有独立的网络栈**，所有出网包都先经过 proxy 容器内的 iptables。

- `nat OUTPUT` 链把非 squid uid 的 80/443 流量 `REDIRECT` 到本地 squid（3128 / 3129），按 uid 把 squid 自身豁免出去
- HTTP：squid 在 intercept 模式下用 `Host` 头匹配 dstdomain，命中 blocklist 直接 deny
- HTTPS：squid 用 ssl-bump 在 SslBump1 peek SNI，命中 blocklist 直接 terminate；其余 splice 直通，不解密、不需要 CA
- 其它端口（如 mcp-gateway 的 8080）不在 NAT 规则里，sandbox 直连，不经过 squid
- 应用程序看不到代理的存在，sandbox 内不再注入 `HTTP_PROXY` / `HTTPS_PROXY`

策略是**默认放行 + blocklist 过滤**：未列入 `config/proxy-rules/blocklist.txt` 的域名全部放行；默认 blocklist 里有 `api.github.com` / `uploads.github.com`，迫使 GitHub 程序化访问只能走 mcp-gateway。

简洁模式下不会启动 `mcp-gateway`，同时也不会给 sandbox 注入 `MCP_GITHUB_URL`。注意默认 blocklist 依然会拦截直连 GitHub API；如果你连 MCP 也不用、但又想直接放开 GitHub API，需要额外调整 `config/proxy-rules/blocklist.txt`。

## 暴露端口

`sandbox` 共享 `proxy` 的 netns，所以容器内任何监听端口都得在 `proxy` 上 publish。默认在 `compose.yaml` / `compose.simple.yaml` 给 proxy 开了 `127.0.0.1:7000-7010:7000-7010`，仅 host loopback 可见，给 sandbox 内 dev server 一段预留区。

要改范围或换端口，在 `.env` 里覆盖：

```env
AGENT_SANDBOX_PUBLISH_PORTS=127.0.0.1:8080:8080            # 单端口
AGENT_SANDBOX_PUBLISH_PORTS=127.0.0.1:7000-7020:7000-7020  # 更宽范围
AGENT_SANDBOX_PUBLISH_PORTS=0.0.0.0:7000-7010:7000-7010    # 暴露到 LAN
```

Docker 没有"运行中容器实时加端口"的 API。改了 `AGENT_SANDBOX_PUBLISH_PORTS` 必须 `bin/agent-sandbox down && bin/agent-sandbox up` 重新创建 proxy 容器才生效——这点跟其它配置型 .env 旋钮不一样。

## MCP 平面

默认模式下，`mcp-gateway` 容器跑 `mcp-proxy`，把 `config/mcp-gateway/servers.json` 里的 stdio server 暴露在 HTTP 路径下。当前唯一的 named server：

- `github`：路径 `http://mcp-gateway:8080/servers/github/mcp`，对应官方 `github-mcp-server stdio`

sandbox 内通过环境变量 `MCP_GITHUB_URL` 引用这个路径。GitHub PAT 只注入 mcp-gateway，sandbox 容器不持有；`mcp-proxy` 透传环境给容器内的 `github-mcp-server`。

## 扩展点

- **加 MCP 服务**：把新的 stdio server 预装进 `mcp-gateway` 镜像，在 `servers.json` 里加一项 named server，路径约定 `/servers/<name>/...`。主 compose 不动。详见 [`docs/extending.md`](docs/extending.md)。
- **改代理黑名单**：编辑 `config/proxy-rules/blocklist.txt`，跑 `scripts/verify.sh` 验证。dstdomain / SNI 都支持前导点匹配子域。
- **透传新环境变量**：在 `compose.yaml` 的 `sandbox.environment` 列表里追加变量名（不带 `=`），Docker compose 会从 host shell 读取并透传。

## 详细文档

- [`docs/architecture.md`](docs/architecture.md)：组件分工与运行流程
- [`docs/security-model.md`](docs/security-model.md)：信任边界、约束模型、已知盲点
- [`docs/persistence.md`](docs/persistence.md)：持久化布局、执行入口审计、清理与迁移
- [`docs/extending.md`](docs/extending.md)：新增 MCP / 调整代理规则 / 注入环境变量
- [`docs/verification.md`](docs/verification.md)：本地静态检查与端到端验证脚本

## 验证

`scripts/verify.sh` 会启动默认模式的完整栈、对放行/阻断/MCP 链路做断言、然后清理。**它会启动和停止容器**，共享环境里别直接跑。
