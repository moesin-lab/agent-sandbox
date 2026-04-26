# 架构说明

## 概览

这个仓库是一个用于运行 Agent 的起步项目，核心思路是在 Docker 管理的沙盒里提供两条受控出口：

- 通过 MCP 服务暴露敏感或高价值能力
- 通过 HTTP 代理提供基于 allowlist 的通用出网能力

顶层入口是 `bin/agent-sandbox`。它会先读取 `config/defaults.env` 中的默认配置，再叠加 `config/profiles/*.env` 中的某个 profile，按 profile 导出对应代理环境变量，最后把生命周期操作交给 `orchestration/compose.yaml` 中的 Docker Compose 编排。

## 组件

### `sandbox/`

`sandbox` 镜像是 Agent 的交互式运行环境。它会挂载：

- `runtime/workspaces` at `/workspace`
- `runtime/logs` at `/runtime/logs`
- `runtime/state` at `/runtime/state`
- `runtime/home` at `/home/node`

它的 entrypoint 会准备运行目录、启动 watchdog、调用 MCP 启动辅助脚本，然后再执行容器主命令。

### `mcp/`

`mcp` 模块包含一组小型服务进程，用来暴露受控能力。当前 starter kit 自带：

- `mcp-github`
- `mcp-web`

`mcp/lib/profile-loader.js` 会校验 MCP profile 的 JSON 定义，用来决定某个 MCP profile 应暴露哪些服务。

### `proxy/`

代理服务运行 Squid，并在启动时把配置好的 allowlist 和 blocklist 拷贝进容器。启用代理的 profile 会注入：

- `HTTP_PROXY=http://proxy:3128`
- `HTTPS_PROXY=http://proxy:3128`

这样沙盒里的普通 CLI 工具就会优先走仓库管理的出网路径，而不是直接无限制联网。

### `orchestration/`

`orchestration/lib/common.sh` 提供项目根定位和 env 文件加载等通用辅助函数。`orchestration/lib/profile.sh` 负责加载所选 profile，并导出 Compose 和 sandbox 容器所需的代理环境变量。

`orchestration/compose.yaml` 把 sandbox、proxy 和 MCP 服务声明成同一个栈。

## 运行流程

1. `bin/agent-sandbox up <profile>` 先加载默认配置和指定 profile。
2. profile 会决定代理环境变量是否启用，以及该模式下预期应有哪些服务。
3. `docker compose` 负责构建并启动整套服务。
4. sandbox 使用仓库内管理的挂载目录来承载 workspace、日志、状态和 home 数据。
5. sandbox 的网络访问会根据所选 profile 直接失败、通过 Squid 转发，或与 MCP sidecar 组合使用。

## 当前范围

这个实现刻意保持在 starter kit 范围内。当前 compose 文件会静态声明所有服务，profile env 文件主要控制的是网络环境和运行意图，而不是动态裁剪 Compose 服务图。所以这里的文档和验证脚本应该被理解为“当前脚手架的使用说明”，而不是“已经完全由策略驱动的编排系统”。
