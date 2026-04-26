# Agent Containment Starter Kit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个面向 macOS + Docker Desktop 的单仓库 Agent containment starter kit，内含 `sandbox`、`mcp`、`proxy` 三个一等模块，并提供 `mcp-only`、`proxy-gated`、`hybrid` 三种可运行模式。

**Architecture:** 仓库以 `bin/agent-sandbox` 作为统一入口，读取 `config/profiles/*.env` 组装运行模式，再通过 `orchestration/compose.yaml` 编排 `sandbox`、`mcp`、`proxy` 三类服务。宿主机运行态统一落在仓库内的 `runtime/` 目录，敏感能力通过仓库内 MCP 服务暴露，普通出网通过仓库内代理白名单治理。

**Tech Stack:** Bash、Docker Compose、Debian-based Node image、Node.js、Express、HTTP proxy（Squid）、jq

---

## File Structure

### Core files and responsibilities

- `README.md`
  - 项目入口文档，说明三种模式、初始化步骤和常用命令。
- `.gitignore`
  - 忽略 `runtime/` 下运行态目录、环境文件和日志文件。
- `bin/agent-sandbox`
  - 统一用户入口，负责 `up/down/shell/logs/doctor` 命令分发。
- `config/defaults.env`
  - 全局默认值，例如镜像名、容器名前缀、默认 profile、runtime 根目录。
- `config/profiles/mcp-only.env`
  - 仅 MCP 模式的配置声明。
- `config/profiles/proxy-gated.env`
  - 代理白名单模式的配置声明。
- `config/profiles/hybrid.env`
  - 混合模式的配置声明。
- `config/mcp-profiles/safe-dev.json`
  - 向 sandbox 暴露的 MCP 服务集合定义。
- `config/proxy-rules/allowlist.txt`
  - 代理允许访问的域名列表。
- `config/proxy-rules/blocklist.txt`
  - 代理显式阻断的域名列表。
- `orchestration/lib/common.sh`
  - 共享 shell 函数：加载 env、计算路径、打印日志、校验依赖。
- `orchestration/lib/profile.sh`
  - profile 解析逻辑，把 profile env 转成 compose 所需环境。
- `orchestration/compose.yaml`
  - 编排 `sandbox`、`mcp-github`、`mcp-web`、`proxy` 服务。
- `sandbox/Dockerfile`
  - Agent 容器镜像定义。
- `sandbox/files/entrypoint.sh`
  - 容器入口脚本，负责运行时目录准备和主命令启动。
- `sandbox/files/watchdog.sh`
  - 守护脚本，负责托管需要常驻的 sidecar 进程。
- `sandbox/files/mcp-start.sh`
  - 容器内 MCP 客户端启动辅助脚本。
- `sandbox/files/shellrc.zsh`
  - 容器内 zsh 初始化，注入项目级环境。
- `mcp/package.json`
  - MCP 服务工作区定义。
- `mcp/services/github/server.js`
  - GitHub MCP 骨架，提供受控占位工具和健康检查。
- `mcp/services/web/server.js`
  - Web MCP 骨架，提供受控搜索/抓取占位工具和健康检查。
- `mcp/lib/profile-loader.js`
  - 读取 `config/mcp-profiles/*.json`，决定暴露哪些工具。
- `proxy/squid.conf`
  - 默认代理实现配置文件。
- `proxy/entrypoint.sh`
  - 启动 Squid，并把规则文件渲染到运行目录。
- `docs/architecture.md`
  - 模块关系和数据流。
- `docs/profiles.md`
  - 三种模式的行为差异。
- `docs/security-model.md`
  - 威胁模型和边界说明。
- `docs/extending.md`
  - 新增 MCP 服务、profile、代理规则的方法。
- `docs/verification.md`
  - 手工与脚本验证步骤。
- `scripts/verify-mcp-only.sh`
  - 验证 `mcp-only` 直连敏感目标失败。
- `scripts/verify-proxy-gated.sh`
  - 验证 `proxy-gated` allowlist 通、blocklist 断。
- `scripts/verify-hybrid.sh`
  - 验证 `hybrid` 普通出网和 MCP 能力同时成立。

## Task 1: Scaffold repository layout and runtime boundaries

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `runtime/workspaces/.gitkeep`
- Create: `runtime/home/.gitkeep`
- Create: `runtime/logs/.gitkeep`
- Create: `runtime/state/.gitkeep`

- [ ] **Step 1: Write the failing test**

```bash
test -d runtime/workspaces
test -d runtime/home
test -d runtime/logs
test -d runtime/state
rg '^runtime/' .gitignore
```

Expected: 目录不存在，`.gitignore` 也不存在。

- [ ] **Step 2: Run test to verify it fails**

Run: `test -d runtime/workspaces && test -f .gitignore`
Expected: 非 0 退出码。

- [ ] **Step 3: Write minimal implementation**

```gitignore
runtime/workspaces/*
runtime/home/*
runtime/logs/*
runtime/state/*
!runtime/workspaces/.gitkeep
!runtime/home/.gitkeep
!runtime/logs/.gitkeep
!runtime/state/.gitkeep
.env
*.log
```

```markdown
# Agent Containment Starter Kit

一个面向 macOS + Docker Desktop 的 Agent 沙盒模板仓库。

## Quick Start

1. 复制环境模板并调整变量。
2. 运行 `bin/agent-sandbox up hybrid`。
3. 用 `bin/agent-sandbox doctor` 验证依赖与目录。
```

- [ ] **Step 4: Run test to verify it passes**

Run: `test -d runtime/workspaces && test -d runtime/home && test -d runtime/logs && test -d runtime/state && rg '^runtime/' .gitignore`
Expected: 所有检查通过，`rg` 输出四条 `runtime/` ignore 规则。

- [ ] **Step 5: Commit**

```bash
git add .gitignore README.md runtime
git commit -m "chore: scaffold repository runtime layout"
```

## Task 2: Add profile-based configuration and shared orchestration helpers

**Files:**
- Create: `config/defaults.env`
- Create: `config/profiles/mcp-only.env`
- Create: `config/profiles/proxy-gated.env`
- Create: `config/profiles/hybrid.env`
- Create: `config/mcp-profiles/safe-dev.json`
- Create: `config/proxy-rules/allowlist.txt`
- Create: `config/proxy-rules/blocklist.txt`
- Create: `orchestration/lib/common.sh`
- Create: `orchestration/lib/profile.sh`

- [ ] **Step 1: Write the failing test**

```bash
test -f config/defaults.env
test -f config/profiles/mcp-only.env
test -f orchestration/lib/profile.sh
```

Expected: 配置文件和共享脚本都不存在。

- [ ] **Step 2: Run test to verify it fails**

Run: `bash -n orchestration/lib/profile.sh`
Expected: 报错 `No such file or directory`。

- [ ] **Step 3: Write minimal implementation**

```env
# config/defaults.env
PROJECT_NAME=agent-sandbox
RUNTIME_DIR=runtime
DEFAULT_PROFILE=hybrid
SANDBOX_IMAGE=agent-sandbox:dev
COMPOSE_PROJECT_NAME=agent_sandbox
MCP_PROFILE=safe-dev
PROXY_RULESET=default
```

```env
# config/profiles/mcp-only.env
PROFILE_NAME=mcp-only
ENABLE_PROXY=0
ENABLE_MCP_GITHUB=1
ENABLE_MCP_WEB=1
SANDBOX_NETWORK_MODE=isolated
```

```env
# config/profiles/proxy-gated.env
PROFILE_NAME=proxy-gated
ENABLE_PROXY=1
ENABLE_MCP_GITHUB=0
ENABLE_MCP_WEB=0
SANDBOX_NETWORK_MODE=proxy
```

```env
# config/profiles/hybrid.env
PROFILE_NAME=hybrid
ENABLE_PROXY=1
ENABLE_MCP_GITHUB=1
ENABLE_MCP_WEB=1
SANDBOX_NETWORK_MODE=proxy
```

```json
{
  "name": "safe-dev",
  "services": ["github", "web"]
}
```

```text
# config/proxy-rules/allowlist.txt
registry.npmjs.org
pypi.org
files.pythonhosted.org
docs.github.com
developer.mozilla.org
```

```text
# config/proxy-rules/blocklist.txt
api.github.com
uploads.github.com
```

```bash
#!/usr/bin/env bash
set -euo pipefail

project_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

load_env_file() {
  local file="$1"
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}
```

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_profile() {
  local root profile
  root="$(project_root)"
  profile="${1:-}"
  load_env_file "$root/config/defaults.env"
  load_env_file "$root/config/profiles/${profile}.env"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash -n orchestration/lib/common.sh && bash -n orchestration/lib/profile.sh && jq -r '.services[]' config/mcp-profiles/safe-dev.json`
Expected: shell 语法检查通过，`jq` 输出 `github` 和 `web`。

- [ ] **Step 5: Commit**

```bash
git add config orchestration/lib
git commit -m "feat: add profile-based configuration layer"
```

## Task 3: Build the unified operator entrypoint

**Files:**
- Create: `bin/agent-sandbox`
- Modify: `README.md`

- [ ] **Step 1: Write the failing test**

```bash
test -x bin/agent-sandbox
./bin/agent-sandbox doctor
```

Expected: 文件不存在或不可执行。

- [ ] **Step 2: Run test to verify it fails**

Run: `./bin/agent-sandbox doctor`
Expected: shell 报 `No such file or directory`。

- [ ] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/orchestration/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/orchestration/lib/profile.sh"

usage() {
  cat <<'EOF'
Usage:
  bin/agent-sandbox up [profile]
  bin/agent-sandbox down
  bin/agent-sandbox shell
  bin/agent-sandbox logs
  bin/agent-sandbox doctor
EOF
}

doctor() {
  command -v docker >/dev/null
  command -v jq >/dev/null
  test -d "$ROOT/runtime/workspaces"
  test -d "$ROOT/runtime/home"
  test -d "$ROOT/runtime/logs"
  test -d "$ROOT/runtime/state"
  echo "doctor: ok"
}

case "${1:-}" in
  up) echo "up not implemented yet in this task" ;;
  down) echo "down not implemented yet in this task" ;;
  shell) echo "shell not implemented yet in this task" ;;
  logs) echo "logs not implemented yet in this task" ;;
  doctor) doctor ;;
  *) usage; exit 1 ;;
esac
```

```markdown
## Commands

- `bin/agent-sandbox up <profile>`
- `bin/agent-sandbox down`
- `bin/agent-sandbox shell`
- `bin/agent-sandbox logs`
- `bin/agent-sandbox doctor`
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x bin/agent-sandbox && ./bin/agent-sandbox doctor`
Expected: 输出 `doctor: ok`。

- [ ] **Step 5: Commit**

```bash
git add bin/agent-sandbox README.md
git commit -m "feat: add unified operator entrypoint"
```

## Task 4: Implement sandbox image and container startup chain

**Files:**
- Create: `sandbox/Dockerfile`
- Create: `sandbox/files/entrypoint.sh`
- Create: `sandbox/files/watchdog.sh`
- Create: `sandbox/files/mcp-start.sh`
- Create: `sandbox/files/shellrc.zsh`
- Modify: `bin/agent-sandbox`

- [ ] **Step 1: Write the failing test**

```bash
test -f sandbox/Dockerfile
docker build -t agent-sandbox:test sandbox
```

Expected: `sandbox/` 不存在，镜像构建失败。

- [ ] **Step 2: Run test to verify it fails**

Run: `docker build -t agent-sandbox:test sandbox`
Expected: `unable to prepare context` 或路径不存在。

- [ ] **Step 3: Write minimal implementation**

```dockerfile
FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    zsh jq curl procps ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY files/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY files/watchdog.sh /usr/local/bin/watchdog.sh
COPY files/mcp-start.sh /usr/local/bin/mcp-start.sh
COPY files/shellrc.zsh /home/node/.zshrc

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/watchdog.sh /usr/local/bin/mcp-start.sh \
    && chown -R node:node /home/node

USER node
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh", "-i"]
```

```bash
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /runtime/logs /runtime/state /workspace
nohup /usr/local/bin/watchdog.sh >> /runtime/logs/watchdog.log 2>&1 &
exec "$@"
```

```bash
#!/usr/bin/env bash
set -euo pipefail

while true; do
  sleep 30
done
```

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "mcp-start stub initialized"
```

```zsh
export PATH="/workspace/bin:$PATH"
export AGENT_SANDBOX_RUNTIME="/runtime"
```

```bash
  up)
    profile="${2:-$DEFAULT_PROFILE}"
    load_profile "$profile"
    docker build -t "$SANDBOX_IMAGE" "$ROOT/sandbox"
    ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker build -t agent-sandbox:test sandbox`
Expected: 镜像成功构建。

- [ ] **Step 5: Commit**

```bash
git add sandbox bin/agent-sandbox
git commit -m "feat: add sandbox container startup chain"
```

## Task 5: Add MCP service skeletons and profile loader

**Files:**
- Create: `mcp/package.json`
- Create: `mcp/lib/profile-loader.js`
- Create: `mcp/services/github/server.js`
- Create: `mcp/services/web/server.js`
- Modify: `README.md`

- [ ] **Step 1: Write the failing test**

```bash
test -f mcp/package.json
node mcp/services/github/server.js
```

Expected: 文件不存在，Node 入口无法执行。

- [ ] **Step 2: Run test to verify it fails**

Run: `node mcp/services/web/server.js`
Expected: `Cannot find module` 或文件不存在。

- [ ] **Step 3: Write minimal implementation**

```json
{
  "name": "agent-sandbox-mcp",
  "private": true,
  "type": "module",
  "dependencies": {
    "express": "^4.21.2"
  },
  "scripts": {
    "github": "node services/github/server.js",
    "web": "node services/web/server.js"
  }
}
```

```js
import fs from "node:fs";

export function loadProfile(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}
```

```js
import express from "express";

const app = express();
app.get("/health", (_req, res) => {
  res.json({ service: "github", ok: true, tools: ["create_pr_stub"] });
});
app.listen(3101, () => {
  console.log("github mcp stub listening on 3101");
});
```

```js
import express from "express";

const app = express();
app.get("/health", (_req, res) => {
  res.json({ service: "web", ok: true, tools: ["search_web_stub", "fetch_url_stub"] });
});
app.listen(3102, () => {
  console.log("web mcp stub listening on 3102");
});
```

```markdown
## MCP Services

- `github`: 受控敏感操作骨架
- `web`: 受控搜索和抓取骨架
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp && npm install && node services/github/server.js`
Expected: 输出 `github mcp stub listening on 3101`。

- [ ] **Step 5: Commit**

```bash
git add mcp README.md
git commit -m "feat: add mcp service skeletons"
```

## Task 6: Add proxy service and connect mode-driven orchestration

**Files:**
- Create: `proxy/squid.conf`
- Create: `proxy/entrypoint.sh`
- Create: `orchestration/compose.yaml`
- Modify: `orchestration/lib/profile.sh`
- Modify: `bin/agent-sandbox`

- [ ] **Step 1: Write the failing test**

```bash
test -f orchestration/compose.yaml
docker compose -f orchestration/compose.yaml config
```

Expected: compose 文件不存在，解析失败。

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose -f orchestration/compose.yaml config`
Expected: `no such file or directory`。

- [ ] **Step 3: Write minimal implementation**

```conf
http_port 3128
acl blocked dstdomain "/etc/squid/blocklist.txt"
http_access deny blocked
http_access allow all
```

```bash
#!/usr/bin/env bash
set -euo pipefail

cp /rules/blocklist.txt /etc/squid/blocklist.txt
exec squid -N -f /etc/squid/squid.conf
```

```yaml
services:
  sandbox:
    build:
      context: ../sandbox
    image: ${SANDBOX_IMAGE}
    volumes:
      - ../runtime/workspaces:/workspace
      - ../runtime/logs:/runtime/logs
      - ../runtime/state:/runtime/state
      - ../runtime/home:/home/node
    environment:
      HTTP_PROXY: ${HTTP_PROXY:-}
      HTTPS_PROXY: ${HTTPS_PROXY:-}
    depends_on:
      - proxy
      - mcp-github
      - mcp-web
  proxy:
    image: ubuntu/squid:latest
    volumes:
      - ../proxy/squid.conf:/etc/squid/squid.conf:ro
      - ../config/proxy-rules:/rules:ro
  mcp-github:
    build:
      context: ../mcp
    command: ["node", "services/github/server.js"]
  mcp-web:
    build:
      context: ../mcp
    command: ["node", "services/web/server.js"]
```

```bash
compose_env() {
  if [[ "${ENABLE_PROXY:-0}" == "1" ]]; then
    export HTTP_PROXY="http://proxy:3128"
    export HTTPS_PROXY="http://proxy:3128"
  else
    export HTTP_PROXY=""
    export HTTPS_PROXY=""
  fi
}
```

```bash
  up)
    profile="${2:-$DEFAULT_PROFILE}"
    load_profile "$profile"
    compose_env
    docker compose -f "$ROOT/orchestration/compose.yaml" up -d --build
    ;;
  down)
    docker compose -f "$ROOT/orchestration/compose.yaml" down
    ;;
  logs)
    docker compose -f "$ROOT/orchestration/compose.yaml" logs --tail=50
    ;;
  shell)
    docker compose -f "$ROOT/orchestration/compose.yaml" exec sandbox zsh -i
    ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose -f orchestration/compose.yaml config`
Expected: compose 配置可成功展开。

- [ ] **Step 5: Commit**

```bash
git add proxy orchestration bin/agent-sandbox
git commit -m "feat: add proxy and compose orchestration"
```

## Task 7: Write documentation and executable verification scripts

**Files:**
- Create: `docs/architecture.md`
- Create: `docs/profiles.md`
- Create: `docs/security-model.md`
- Create: `docs/extending.md`
- Create: `docs/verification.md`
- Create: `scripts/verify-mcp-only.sh`
- Create: `scripts/verify-proxy-gated.sh`
- Create: `scripts/verify-hybrid.sh`
- Modify: `README.md`

- [ ] **Step 1: Write the failing test**

```bash
test -f docs/verification.md
test -x scripts/verify-mcp-only.sh
```

Expected: 文档和脚本不存在。

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/verify-mcp-only.sh`
Expected: `No such file or directory`。

- [ ] **Step 3: Write minimal implementation**

```markdown
# Verification

## mcp-only

1. 运行 `bin/agent-sandbox up mcp-only`
2. 进入 sandbox 执行 `curl https://api.github.com`
3. 预期请求失败
```

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/agent-sandbox" up mcp-only
if docker compose -f "$ROOT/orchestration/compose.yaml" exec -T sandbox curl -I https://api.github.com; then
  echo "expected api.github.com to be blocked"
  exit 1
fi
echo "verify-mcp-only: ok"
```

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/agent-sandbox" up proxy-gated
docker compose -f "$ROOT/orchestration/compose.yaml" exec -T sandbox curl -I https://registry.npmjs.org >/dev/null
if docker compose -f "$ROOT/orchestration/compose.yaml" exec -T sandbox curl -I https://api.github.com; then
  echo "expected api.github.com to be blocked"
  exit 1
fi
echo "verify-proxy-gated: ok"
```

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/bin/agent-sandbox" up hybrid
docker compose -f "$ROOT/orchestration/compose.yaml" exec -T sandbox curl -I https://registry.npmjs.org >/dev/null
docker compose -f "$ROOT/orchestration/compose.yaml" exec -T mcp-web curl -I http://localhost:3102/health >/dev/null
echo "verify-hybrid: ok"
```

```markdown
## Validation scripts

- `scripts/verify-mcp-only.sh`
- `scripts/verify-proxy-gated.sh`
- `scripts/verify-hybrid.sh`
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scripts/verify-mcp-only.sh scripts/verify-proxy-gated.sh scripts/verify-hybrid.sh && test -x scripts/verify-mcp-only.sh && test -f docs/verification.md`
Expected: 三个脚本都可执行，验证文档存在。

- [ ] **Step 5: Commit**

```bash
git add docs scripts README.md
git commit -m "docs: add verification and extension guides"
```

## Self-Review

### Spec coverage

- `sandbox`、`mcp`、`proxy` 三大模块：由 Task 4、Task 5、Task 6 覆盖。
- 三种运行模式：由 Task 2 的 profile 配置和 Task 6 的 compose 编排覆盖。
- 仓库内 `runtime/` 目录与 ignore 策略：由 Task 1 覆盖。
- 统一入口和宿主机整合：由 Task 3 覆盖。
- 验证脚本与文档：由 Task 7 覆盖。

没有发现 spec 中完全未落入任务的核心要求。

### Placeholder scan

- 计划中没有 `TODO`、`TBD`、`implement later` 之类占位描述。
- 每个任务都给出了明确文件路径、命令和最小代码片段。

### Type consistency

- 统一入口固定为 `bin/agent-sandbox`。
- 标准 profile 名固定为 `mcp-only`、`proxy-gated`、`hybrid`。
- 运行目录固定为 `runtime/workspaces`、`runtime/home`、`runtime/logs`、`runtime/state`。
- MCP profile 固定示例为 `safe-dev`，前后命名一致。
