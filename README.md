# Agent Containment Starter Kit

一个面向 macOS + Docker Desktop 的 Agent 沙盒模板仓库。

## 这个项目解决什么问题

这个仓库不是单纯把 Agent 塞进 Docker。它要解决的是更具体的问题：

- Agent 不应该直接拿着 shell 去访问敏感外部接口
- 普通依赖下载和网页访问需要有受控出口
- 新增 MCP 服务时，不应该每次都改主 `compose` 拓扑

当前实现把系统拆成三层：

- `sandbox`：Agent 运行舱
- `proxy`：普通出网的 allowlist/blocklist 控制层
- `mcp-gateway`：敏感或高价值能力的受控 MCP 出口

## 仓库约定

最重要的目录分工如下：

- `config/`
  - 放配置源
  - 例如默认值、运行模式、MCP gateway 配置、代理规则
- `deploy/compose/`
  - 放部署拓扑
  - `compose.yaml` 是唯一主入口
- `sandbox/`
  - Agent 容器镜像和启动脚本
- `proxy/`
  - 代理镜像和 Squid 配置
- `mcp-gateway/`
  - MCP gateway 镜像
  - 内置 `mcp-proxy` 和 `github-mcp-server`
- `runtime/`
  - 宿主机上的运行态目录
  - 工作区、日志、状态、持久化 home 都在这里

一个简单的判断标准：

- `config` 负责“应该怎样”
- `deploy` 负责“实际怎么起”

当前 `config/` 里真正会参与运行链路的只有四类文件：

- `config/defaults.env`
  - 全局默认值，例如镜像名、`COMPOSE_ROOT`、`MCP_GITHUB_PATH`
- `config/profiles/*.env`
  - 运行模式，例如 `mcp-only`、`proxy-gated`、`hybrid`
- `config/mcp-gateway/servers.json`
  - `mcp-proxy` 的 named server 配置
- `config/proxy-rules/*.txt`
  - 代理 allowlist / blocklist

这里的默认结构是固定拓扑：

- `sandbox`
- `proxy`
- `mcp-gateway`

以后新增 MCP 时，优先改的是 `mcp-gateway` 镜像和 `servers.json`，不是主 `compose` 拓扑。

## 快速开始

1. 先读 `config/defaults.env` 和 `config/profiles/*.env`，确认默认镜像名、compose 根目录和运行模式符合你的机器环境。
2. 在宿主机环境里导出 GitHub PAT，例如：

```bash
export GITHUB_PERSONAL_ACCESS_TOKEN=your_token_here
```

3. 运行 `bin/agent-sandbox doctor` 检查本地依赖和目录。
4. 运行 `bin/agent-sandbox up hybrid` 启动默认开发模式。

如果你只是想确认本地结构没坏，先跑：

```bash
bin/agent-sandbox doctor
docker compose -p agent_sandbox -f deploy/compose/compose.yaml config
```

这两步不会启动现有容器，只会做本地静态检查。

## 运行模式

- `mcp-only`: 默认不走通用外网，强调通过 MCP 暴露能力
- `proxy-gated`: 通过仓库代理访问 allowlist 目标
- `hybrid`: 同时保留代理出网和 MCP gateway

这些模式定义在 `config/profiles/*.env`，目前主要影响：

- 是否注入 `HTTP_PROXY` / `HTTPS_PROXY`
- 对当前运行意图的约束表达
- `proxy` 和 `mcp-gateway` 在这个模式下的预期角色

它们现在还不会动态删除 compose 服务，所以要把它理解成“运行策略配置”，不是“完整服务编排器”。

## Compose 入口

- 主入口：`deploy/compose/compose.yaml`
- 当前服务固定为：
  - `sandbox`
  - `proxy`
  - `mcp-gateway`

现在不再通过 compose 片段按服务名启用 MCP。默认策略是把 MCP 能力收口到一个 `mcp-gateway` 容器里，再由 `mcp-proxy` 的 named servers 提供多路径访问。

原生静态检查可以直接用：

```bash
docker compose -p agent_sandbox -f deploy/compose/compose.yaml config
```

## GitHub MCP 路径

当前内置的 named server 只有一个：

- `github`

对 sandbox 暴露的默认路径是：

- `http://mcp-gateway:8080/servers/github/mcp`

仓库会把这个值注入到 sandbox 的 `MCP_GITHUB_URL` 环境变量里，便于在容器内统一引用。

`mcp-gateway` 内部用的是：

- `mcp-proxy`
- `github/github-mcp-server`

其中 `mcp-proxy` 只负责协议桥接和路径分发，普通出网仍然由独立的 `proxy` 容器负责。

GitHub 凭据不会写进 `servers.json`。当前约定是：

- 宿主机导出 `GITHUB_PERSONAL_ACCESS_TOKEN`
- compose 把它只注入 `mcp-gateway`
- `mcp-proxy` 再把环境透传给容器内的 `github-mcp-server stdio`

## 常见操作

启动默认模式：

```bash
bin/agent-sandbox up
```

启动指定模式：

```bash
bin/agent-sandbox up mcp-only
bin/agent-sandbox up proxy-gated
bin/agent-sandbox up hybrid
```

查看日志：

```bash
bin/agent-sandbox logs
```

进入 sandbox：

```bash
bin/agent-sandbox shell
```

停止栈：

```bash
bin/agent-sandbox down
```

直接用原生 compose 展开当前部署，可以参考：

```bash
docker compose -p agent_sandbox -f deploy/compose/compose.yaml config
```

## 新增一个 MCP 服务怎么做

最短路径是：

1. 把新的 `stdio` MCP server 预装进 `mcp-gateway` 镜像
2. 在 `config/mcp-gateway/servers.json` 里增加一个 named server
3. 约定它的路径为 `/servers/<name>/...`
4. 运行 `docker compose ... config` 或 `bin/agent-sandbox doctor` 做静态检查

这样新增一个 MCP 时：

- 主 `compose` 不需要修改
- 对 sandbox 仍然只有一个稳定入口
- 新能力通过 named server 路径扩展，而不是继续平铺容器

详细说明见：

- `docs/architecture.md`
- `docs/profiles.md`
- `docs/security-model.md`
- `docs/extending.md`
- `docs/verification.md`

## 常用命令

- `bin/agent-sandbox up <profile>`
- `bin/agent-sandbox down`
- `bin/agent-sandbox shell`
- `bin/agent-sandbox logs`
- `bin/agent-sandbox doctor`

## 当前内置 MCP

- `github`: 通过 `mcp-gateway` 暴露在 `/servers/github/mcp`

`mcp-gateway/` 当前提供的是一个真正的 bridge 容器，而不是 mock sidecar。它会把官方 `github-mcp-server stdio` 挂到 `mcp-proxy` 的 named server 路径下。

## 验证脚本

- `scripts/verify-mcp-only.sh`
- `scripts/verify-proxy-gated.sh`
- `scripts/verify-hybrid.sh`

这些脚本会启动和停止本地栈。共享环境里不要直接跑。
