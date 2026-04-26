# 架构说明

## 概览

这个仓库是一个用于运行 Agent 的起步项目，核心思路是在 Docker 管理的沙盒里提供两条受控出口：

- 通过 MCP 服务暴露敏感或高价值能力
- 通过 HTTP 代理提供基于 allowlist 的通用出网能力

顶层入口是 `bin/agent-sandbox`。它会读取 `config/defaults.env` 中的默认配置，然后直接启动 `deploy/compose/compose.yaml` 里定义的固定拓扑。

## 组件

### `sandbox/`

`sandbox` 镜像是 Agent 的交互式运行环境。它会挂载：

- `runtime/workspaces` at `/workspace`
- `runtime/logs` at `/runtime/logs`
- `runtime/state` at `/runtime/state`
- `runtime/home` at `/home/node`

它的 entrypoint 会准备运行目录、启动 watchdog、调用 MCP 启动辅助脚本，然后再执行容器主命令。

### `mcp-gateway/`

`mcp-gateway` 模块是 MCP 平面的统一入口。当前它做两件事：

- 运行 `mcp-proxy`
- 在容器内拉起官方 `github-mcp-server stdio`

`config/mcp-gateway/servers.json` 决定 named servers 的路径映射。当前内置的 server 名是 `github`，因此对 sandbox 暴露的路径是 `/servers/github/mcp`。

### `proxy/`

代理服务运行 Squid，并在启动时把配置好的 allowlist 和 blocklist 拷贝进容器。当前固定向 sandbox 注入：

- `HTTP_PROXY=http://proxy:3128`
- `HTTPS_PROXY=http://proxy:3128`

这样沙盒里的普通 CLI 工具就会优先走仓库管理的出网路径，而不是直接无限制联网。

### `orchestration/`

`orchestration/lib/common.sh` 提供项目根定位和 env 文件加载等通用辅助函数。

`deploy/compose/compose.yaml` 直接声明三个稳定服务和网络：

- `sandbox`
- `proxy`
- `mcp-gateway`

## 运行流程

1. `bin/agent-sandbox up` 先加载默认配置。
2. `docker compose` 直接以 `deploy/compose/compose.yaml` 启动固定拓扑。
3. sandbox 使用仓库内管理的挂载目录来承载 workspace、日志、状态和 home 数据。
4. sandbox 的普通网络访问固定通过 Squid 转发；MCP 工具流量固定走 `mcp-gateway` 的 named server 路径。

## 当前范围

这个实现刻意保持在 starter kit 范围内。当前主 compose 使用固定拓扑，新增 MCP 的默认方式是扩展 `mcp-gateway` 镜像和 named server 配置，而不是继续膨胀 compose 服务图。
