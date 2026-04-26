# 架构说明

## 概览

这个仓库是一个用于运行 Agent 的起步项目，核心思路是在 Docker 管理的沙盒里提供两条受控出口：

- 通过 MCP 服务暴露敏感或高价值能力
- 通过 HTTP 代理提供基于 allowlist 的通用出网能力

顶层入口是 `bin/agent-sandbox`。它会先读取 `config/defaults.env` 中的默认配置，再叠加 `config/profiles/*.env` 中的某个 profile，按 profile 导出对应代理环境变量，随后以 `deploy/compose/compose.yaml` 为主入口，再按 `config/mcp/enabled.txt` 自动拼接 `deploy/compose/mcp/<name>.yaml` 片段。

## 组件

### `sandbox/`

`sandbox` 镜像是 Agent 的交互式运行环境。它会挂载：

- `runtime/workspaces` at `/workspace`
- `runtime/logs` at `/runtime/logs`
- `runtime/state` at `/runtime/state`
- `runtime/home` at `/home/node`

它的 entrypoint 会准备运行目录、启动 watchdog、调用 MCP 启动辅助脚本，然后再执行容器主命令。

### `mcp/`

`mcp` 模块提供共享基础镜像，具体 MCP 能力通过 compose 片段接入。当前 starter kit 自带：

- `mcp-github`
- `mcp-web`

`mcp/Dockerfile` 提供共享基础镜像，让多个 `mcp-*` 服务在不重复造轮子的前提下复用同一构建基座。哪些 MCP 真的接入当前部署，不由容器内 profile 再决定，而是直接由 `config/mcp/enabled.txt` 和对应的 compose 片段决定。

### `proxy/`

代理服务运行 Squid，并在启动时把配置好的 allowlist 和 blocklist 拷贝进容器。启用代理的 profile 会注入：

- `HTTP_PROXY=http://proxy:3128`
- `HTTPS_PROXY=http://proxy:3128`

这样沙盒里的普通 CLI 工具就会优先走仓库管理的出网路径，而不是直接无限制联网。

### `orchestration/`

`orchestration/lib/common.sh` 提供项目根定位和 env 文件加载等通用辅助函数。`orchestration/lib/profile.sh` 负责加载所选 profile，并导出 Compose 和 sandbox 容器所需的代理环境变量。

`deploy/compose/compose.yaml` 声明稳定主干服务和网络；`deploy/compose/mcp/<name>.yaml` 为单个 MCP 服务提供可插拔片段。

## 运行流程

1. `bin/agent-sandbox up <profile>` 先加载默认配置和指定 profile。
2. profile 会决定代理环境变量是否启用，以及该模式下预期应有哪些服务。
3. `docker compose` 以 `deploy/compose/compose.yaml` 为主文件，并按启用列表叠加 MCP 片段。
4. sandbox 使用仓库内管理的挂载目录来承载 workspace、日志、状态和 home 数据。
5. sandbox 的网络访问会根据所选 profile 直接失败、通过 Squid 转发，或与 MCP sidecar 组合使用。

## 当前范围

这个实现刻意保持在 starter kit 范围内。当前主 compose 只承载稳定基础设施，MCP 服务通过片段接入；profile env 文件主要控制的是网络环境和运行意图，而不是完全动态生成服务图。所以这里的文档和验证脚本应该被理解为“当前脚手架的使用说明”，而不是“已经完全由策略驱动的编排系统”。
