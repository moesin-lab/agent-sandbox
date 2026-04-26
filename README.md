# Agent Containment Starter Kit

一个面向 macOS + Docker Desktop 的 Agent 沙盒模板仓库。

## Quick Start

1. 复制环境模板并调整变量。
2. 运行 `bin/agent-sandbox up hybrid`。
3. 用 `bin/agent-sandbox doctor` 验证依赖与目录。

## 运行模式

- `mcp-only`: 默认不走通用外网，强调通过 MCP 暴露能力
- `proxy-gated`: 通过仓库代理访问 allowlist 目标
- `hybrid`: 同时保留代理出网和 MCP sidecar

## Compose 入口

- 主入口：`deploy/compose/compose.yaml`
- MCP 扩展：`deploy/compose/mcp/<name>.yaml`
- 启用列表：`config/mcp/enabled.txt`
- 也可以直接使用原生 compose 叠加：
  - `docker compose -f deploy/compose/compose.yaml -f deploy/compose/mcp/github.yaml -f deploy/compose/mcp/web.yaml config`

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

## 验证脚本

- `scripts/verify-mcp-only.sh`
- `scripts/verify-proxy-gated.sh`
- `scripts/verify-hybrid.sh`
