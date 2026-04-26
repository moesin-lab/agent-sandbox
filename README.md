# Agent Containment Starter Kit

一个面向 macOS + Docker Desktop 的 Agent 沙盒模板仓库。

## Quick Start

1. 复制环境模板并调整变量。
2. 运行 `bin/agent-sandbox up hybrid`。
3. 用 `bin/agent-sandbox doctor` 验证依赖与目录。

## Commands

- `bin/agent-sandbox up <profile>`
- `bin/agent-sandbox down`
- `bin/agent-sandbox shell`
- `bin/agent-sandbox logs`
- `bin/agent-sandbox doctor`

## MCP Services

- `github`: 受控敏感操作骨架
- `web`: 受控搜索和抓取骨架
