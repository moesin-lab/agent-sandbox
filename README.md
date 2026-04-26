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
- `mcp-*`：敏感或高价值能力的受控出口

## 仓库约定

最重要的目录分工如下：

- `config/`
  - 放配置源
  - 例如默认值、profile、MCP 启用列表、代理规则
- `deploy/compose/`
  - 放部署拓扑
  - `compose.yaml` 是主干
  - `mcp/*.yaml` 是单个 MCP 服务片段
- `sandbox/`
  - Agent 容器镜像和启动脚本
- `proxy/`
  - 代理镜像和 Squid 配置
- `mcp/`
  - MCP 共享基础镜像和服务代码
- `runtime/`
  - 宿主机上的运行态目录
  - 工作区、日志、状态、持久化 home 都在这里

一个简单的判断标准：

- `config` 负责“应该怎样”
- `deploy` 负责“实际怎么起”

## 快速开始

1. 先读 `config/defaults.env` 和 `config/profiles/*.env`，确认默认镜像名、compose 根目录和运行模式符合你的机器环境。
2. 运行 `bin/agent-sandbox doctor` 检查本地依赖和目录。
3. 运行 `bin/agent-sandbox up hybrid` 启动默认开发模式。

如果你只是想确认本地结构没坏，先跑：

```bash
bin/agent-sandbox doctor
docker compose -p agent_sandbox \
  -f deploy/compose/compose.yaml \
  -f deploy/compose/mcp/github.yaml \
  -f deploy/compose/mcp/web.yaml \
  config
```

这两步不会启动现有容器，只会做本地静态检查。

## 运行模式

- `mcp-only`: 默认不走通用外网，强调通过 MCP 暴露能力
- `proxy-gated`: 通过仓库代理访问 allowlist 目标
- `hybrid`: 同时保留代理出网和 MCP sidecar

这些模式定义在 `config/profiles/*.env`，目前主要影响：

- 是否注入 `HTTP_PROXY` / `HTTPS_PROXY`
- 对当前运行意图的约束表达
- MCP 和代理在这个模式下的预期角色

它们现在还不会动态删除 compose 服务，所以要把它理解成“运行策略配置”，不是“完整服务编排器”。

## Compose 入口

- 主入口：`deploy/compose/compose.yaml`
- MCP 扩展：`deploy/compose/mcp/<name>.yaml`
- 启用列表：`config/mcp/enabled.txt`
- 也可以直接使用原生 compose 叠加：
  - `docker compose -f deploy/compose/compose.yaml -f deploy/compose/mcp/github.yaml -f deploy/compose/mcp/web.yaml config`

这套结构的重点是：

- 主 `compose` 只放稳定基础设施
- 每个 MCP 独立一个 compose 片段
- 新增 MCP 时，通常只需要加一个 `deploy/compose/mcp/<name>.yaml`
- 不需要把主 `compose` 越改越大

## MCP 服务是怎么启用的

当前默认启用列表在：

- `config/mcp/enabled.txt`

`bin/agent-sandbox` 会读取这个文件，然后自动拼接：

- `deploy/compose/compose.yaml`
- `deploy/compose/mcp/github.yaml`
- `deploy/compose/mcp/web.yaml`
- 以及未来新增的其他 MCP 片段

如果你不想走项目封装，也可以直接手写 `docker compose -f ...`。

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

直接用原生 compose 展开当前启用的 MCP 片段，可以参考：

```bash
docker compose -p agent_sandbox \
  -f deploy/compose/compose.yaml \
  -f deploy/compose/mcp/github.yaml \
  -f deploy/compose/mcp/web.yaml \
  config
```

## 新增一个 MCP 服务怎么做

最短路径是：

1. 在 `mcp/services/<name>/` 下增加服务代码
2. 如需复用共享基座，继续使用 `mcp/Dockerfile`
3. 增加 `deploy/compose/mcp/<name>.yaml`
4. 把 `<name>` 写入 `config/mcp/enabled.txt`
5. 运行 `docker compose ... config` 或 `bin/agent-sandbox doctor` 做静态检查

这样新增一个 MCP 时：

- 主 `compose` 不需要修改
- 已有服务通常不需要重新构建
- 只会在 compose 片段层增加一个新服务定义

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

## MCP 服务

- `github`: 受控敏感操作骨架
- `web`: 受控搜索和抓取骨架

`mcp/` 当前提供的是共享基础镜像和最小服务骨架。它更像一个起步版本，不是完整的 MCP 平台。

## 验证脚本

- `scripts/verify-mcp-only.sh`
- `scripts/verify-proxy-gated.sh`
- `scripts/verify-hybrid.sh`

这些脚本会启动和停止本地栈。共享环境里不要直接跑。
