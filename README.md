# Agent Containment Starter Kit

面向 macOS + Docker Desktop 的 Agent 沙盒模板：在容器里跑 Claude Code / Codex 等编码 Agent，把它们的网络出口收口到一个透明代理 + 一个 MCP 网关，避免直接拿 shell 撞敏感 API。

## 它要解决什么

- Agent 的普通出网应该有受控出口，但又不能把开发体验搞坏
- 敏感能力（GitHub、未来扩展）应该走显式 MCP 通道，而不是裸 `curl`
- 新增 MCP 服务时不应该每次都改主 compose 拓扑

当前实现是固定的三服务拓扑：

- `sandbox`：Agent 运行舱，预装 `claude` 和 `codex`
- `proxy`：透明 HTTP/HTTPS 代理（Squid intercept + ssl-bump peek/splice），默认放行 + blocklist 过滤
- `mcp-gateway`：基于 `mcp-proxy` 的 MCP 平面，目前内置 `github-mcp-server`

## 仓库结构

```
compose.yaml             # 唯一部署拓扑，docker compose 默认查找
bin/agent-sandbox        # up / down / shell / logs / doctor
sandbox/                 # Agent 容器镜像
proxy/                   # Squid 透明代理镜像
mcp-gateway/             # MCP 网关镜像（mcp-proxy + github-mcp-server）
config/
  mcp-gateway/servers.json   # mcp-proxy 的 named server 配置
  proxy-rules/blocklist.txt  # 代理黑名单
runtime/                 # 宿主机上的运行态目录（workspace / logs / state / home）
scripts/verify.sh        # 端到端验证脚本
docs/                    # 架构、安全模型、扩展指南、验证说明
```

镜像名等覆盖项已经在 `compose.yaml` 里以 `${VAR:-default}` 形式给出默认值，需要覆盖时在仓库根放一个 `.env`，Docker compose 会自动加载。

## 快速开始

宿主机环境里准备好需要透传的凭据，按需导出：

```bash
# GitHub 凭据按用途分两层（推荐用两个不同的 token）：
export GITHUB_PERSONAL_ACCESS_TOKEN=...   # 只给 mcp-gateway，做 issue/PR/org 这类高权限 API
export GITHUB_TOKEN=...                   # 只给 sandbox 内的 git CLI clone/pull/push
                                          # 推荐 fine-grained PAT，scope 限到具体仓库

# Agent CLI 的 API key（可选，未设置走 oauth 流程）
export ANTHROPIC_API_KEY=...
export OPENAI_API_KEY=...
```

`GITHUB_TOKEN` 没设的话，sandbox 内对私有仓的 `git` 操作会以匿名失败；公开仓 clone 不受影响。两个 GitHub token 填同一个值也行，那就是主动放弃这层隔离。`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` 没设也行，CLI 会回退到 oauth；凭据落在持久化的 `runtime/home` 卷里，下次启动复用。

启动：

```bash
bin/agent-sandbox doctor   # 静态检查依赖和目录
bin/agent-sandbox up       # docker compose up -d
bin/agent-sandbox shell    # 进 sandbox 容器
```

停止：`bin/agent-sandbox down`。看日志：`bin/agent-sandbox logs`。

## 网络模型

`sandbox` 通过 `network_mode: "service:proxy"` 共享 `proxy` 容器的 network namespace，所以它**没有独立的网络栈**，所有出网包都先经过 proxy 容器内的 iptables。

- `nat OUTPUT` 链把非 squid uid 的 80/443 流量 `REDIRECT` 到本地 squid（3128 / 3129），按 uid 把 squid 自身豁免出去
- HTTP：squid 在 intercept 模式下用 `Host` 头匹配 dstdomain，命中 blocklist 直接 deny
- HTTPS：squid 用 ssl-bump 在 SslBump1 peek SNI，命中 blocklist 直接 terminate；其余 splice 直通，不解密、不需要 CA
- 其它端口（如 mcp-gateway 的 8080）不在 NAT 规则里，sandbox 直连，不经过 squid
- 应用程序看不到代理的存在，sandbox 内不再注入 `HTTP_PROXY` / `HTTPS_PROXY`

策略是**默认放行 + blocklist 过滤**：未列入 `config/proxy-rules/blocklist.txt` 的域名全部放行；默认 blocklist 里有 `api.github.com` / `uploads.github.com`，迫使 GitHub 程序化访问只能走 mcp-gateway。

## MCP 平面

`mcp-gateway` 容器跑 `mcp-proxy`，把 `config/mcp-gateway/servers.json` 里的 stdio server 暴露在 HTTP 路径下。当前唯一的 named server：

- `github`：路径 `http://mcp-gateway:8080/servers/github/mcp`，对应官方 `github-mcp-server stdio`

sandbox 内通过环境变量 `MCP_GITHUB_URL` 引用这个路径。GitHub PAT 只注入 mcp-gateway，sandbox 容器不持有；`mcp-proxy` 透传环境给容器内的 `github-mcp-server`。

## 扩展点

- **加 MCP 服务**：把新的 stdio server 预装进 `mcp-gateway` 镜像，在 `servers.json` 里加一项 named server，路径约定 `/servers/<name>/...`。主 compose 不动。详见 [`docs/extending.md`](docs/extending.md)。
- **改代理黑名单**：编辑 `config/proxy-rules/blocklist.txt`，跑 `scripts/verify.sh` 验证。dstdomain / SNI 都支持前导点匹配子域。
- **透传新环境变量**：在 `compose.yaml` 的 `sandbox.environment` 列表里追加变量名（不带 `=`），Docker compose 会从 host shell 读取并透传。

## 详细文档

- [`docs/architecture.md`](docs/architecture.md)：组件分工与运行流程
- [`docs/security-model.md`](docs/security-model.md)：信任边界、约束模型、已知盲点
- [`docs/extending.md`](docs/extending.md)：新增 MCP / 调整代理规则 / 注入环境变量
- [`docs/verification.md`](docs/verification.md)：本地静态检查与端到端验证脚本

## 验证

`scripts/verify.sh` 会启动整个本地栈、对放行/阻断/MCP 链路做断言、然后清理。**它会启动和停止容器**，共享环境里别直接跑。
