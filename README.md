# Agent Containment Starter Kit

面向 macOS + Docker Desktop 的 Agent 沙盒模板：在容器里跑 Claude Code / Codex 等编码 Agent，把出网收口到一个透明代理（默认放行 + blocklist）+ 一个 MCP 网关，避免 sandbox 直接拿 shell 撞敏感 API。

两套启动拓扑：

- 默认：`sandbox` + `proxy` + `mcp-gateway`
- 简洁：`sandbox` + `proxy`（不启用 MCP）

## 快速开始

宿主机按需导出凭据（都是可选；CLI 没拿到 API key 会自动走 oauth）：

```bash
export ANTHROPIC_API_KEY=...
export OPENAI_API_KEY=...
export GITHUB_PERSONAL_ACCESS_TOKEN=...   # 只注入 mcp-gateway，sandbox 不持有
```

启动并进入 sandbox：

```bash
bin/agent-sandbox doctor   # 静态检查依赖与目录
bin/agent-sandbox up       # 默认拓扑
bin/sandbox                # 进入容器终端（未启动会先 up）
```

简洁拓扑：

```bash
bin/agent-sandbox up simple
bin/sandbox                # 自动沿用最近一次启动模式
```

停止 / 看日志：

```bash
bin/agent-sandbox down
bin/agent-sandbox logs
```

### 装到 PATH（可选）

不想每次都 `bin/agent-sandbox` 这么打，加一条到 PATH 即可，从任意目录跑都不影响 compose 解析（脚本会自动定位 repo 根，并用 `--project-directory` 把相对路径锁回去）。两种写法二选一：

```bash
# 跟着 repo 走
echo 'export PATH="$PATH:/path/to/agent-sandbox/bin"' >> ~/.zshrc

# 或者 symlink 到已有 PATH 目录
ln -s /path/to/agent-sandbox/bin/agent-sandbox ~/.local/bin/agent-sandbox
ln -s /path/to/agent-sandbox/bin/sandbox       ~/.local/bin/sandbox
```

之后 `agent-sandbox up` / `sandbox` 在任何 cwd 都能用。

### 在 host 目录直接调容器内 CLI

`agent-sandbox <cli> [args...]` 把 host cwd 映射到容器里的 `/workspace/<相对子路径>`，`cd` 过去再 `exec`。cwd 在 workspace 挂载范围（`AGENT_SANDBOX_WORKSPACE_DIR`，默认 `./runtime/workspaces`）之外时，回退到 `/workspace` 并在 stderr 提示，不拒绝。

```bash
cd runtime/workspaces/myproj/api
agent-sandbox claude              # 等价 cd /workspace/myproj/api 后跑 claude
agent-sandbox codex
agent-sandbox pwd                 # 调试映射：输出 /workspace/myproj/api
```

任何容器内 `PATH` 上的二进制都能这么调（镜像自带的 `claude` / `codex` / `mails`、用户在 `/tool-bin/user/` 装的、`nix-portable` 装的），不限白名单。

### 自举（让 sandbox 内的 agent 编辑 sandbox 自己的代码）

把这份 repo 自己挂进容器 `/self`，agent 在 sandbox 里就能改 `sandbox/Dockerfile` / `compose.yaml` / `scripts/verify.sh` / `docs/` 等，host 侧立即可见。

`.env` 里设 host 上 repo 的绝对路径：

```env
AGENT_SANDBOX_SELF_DIR=/Users/me/code/agent-sandbox
```

启动时加 `--self`：

```bash
bin/agent-sandbox up --self     # 默认拓扑 + /self 挂载
bin/agent-sandbox up simple --self
```

之后从 host 上 repo 任意子目录跑 `agent-sandbox <cli>`，cwd 自动映射到容器里的 `/self/<相对路径>`：

```bash
cd ~/code/agent-sandbox/sandbox
agent-sandbox claude       # 进容器后 cwd = /self/sandbox
```

`/self/runtime` 在容器里看得见，但里面的内容跟容器自己运行用的 `/state`、`/home/node`、`/workspace` 是同一份 host 数据；agent 只要不在 `/self/runtime/` 下做破坏性改动即可（跟它直接对 `/state` 干同样的事一样危险）。`.gitignore` 已经把 `runtime/*` 排掉，`git status` 在 `/self` 里不会被运行态污染。

`/self` 下有几处刻意被遮，sandbox 里看到的是空文件 / 空只读目录，host 真实内容不变：

| 路径 | 遮的原因 |
| --- | --- |
| `/self/.env` | 含 `GITHUB_PERSONAL_ACCESS_TOKEN`，PAT 只该让 mcp-gateway 看见 |
| `/self/config/proxy-rules/` | sandbox 改 blocklist 等于自己给自己开后门，proxy 重启后生效 |
| `/self/config/mcp-gateway/` | sandbox 改 servers.json 等于自己塞新 MCP server / 改凭据路径 |

这些是 enforcement 侧的配置，自举 agent 想改就走 host：在外面编辑、`bin/agent-sandbox down && up` 重建。

需要重建容器才能切换：sandbox 跑着时改 `--self` / 改 `AGENT_SANDBOX_SELF_DIR` 都得 `bin/agent-sandbox down && bin/agent-sandbox up [--self]`。

## 常用配置

主要旋钮在 `.env`（从 `.env.example` 复制）。下面只列最常碰的几项，完整列表见 `.env.example`。

| 旋钮 | 用途 |
| --- | --- |
| `AGENT_SANDBOX_WORKSPACE_DIR` | 把工作目录指到自定义 host 路径，例如 `/Users/me/dev/sandbox-work` |
| `AGENT_SANDBOX_WORKSPACE_MODE=ro` | 只读挂载工作目录 |
| `AGENT_SANDBOX_HOME_DIR` / `_STATE_DIR` / `_LOGS_DIR` / `_TOOL_BIN_DIR` | 把对应运行态目录指到自定义路径 |
| `AGENT_SANDBOX_PUBLISH_PORTS` | sandbox 内监听端口在 host 上的映射，默认 `127.0.0.1:7000-7010:7000-7010`，改后需要 `down && up` |
| `SANDBOX_MEMORY_LIMIT` / `SANDBOX_CPUS` / `SANDBOX_PIDS_LIMIT` | 资源上限 |
| `ENABLE_PASSWORDLESS_SUDO=1` + `AGENT_SANDBOX_NO_NEW_PRIVILEGES=false` | 可信会话临时开容器内 sudo（会弱化沙盒） |

不要把 host 上的 `~/.ssh`、`~/.aws`、Docker socket 等敏感目录指到这些挂载路径。

## 容器内常见操作

- `~/.<tool>` 下随手写入会自然持久化（home 是 host bind mount）
- 持久化 `KEY=value` 环境变量：写 `/state/env.local`
- 持久化 shell 自定义：写 `/state/shell/{zshrc,zshenv,bashrc,profile}.local`（直接改 `~/.zshrc` 会被每次启动覆盖）
- 装 npm 全局包：`npm i -g <pkg>` 自动落 `/tool-bin/user/npm-global/`，下次 shell 即在 PATH
- 装系统级二进制：`nix-portable nix-env -iA nixpkgs.ffmpeg`（首次会做一次 nix store bootstrap）
- 镜像自带：`claude`（运行时按需下载）、`codex`、`mails`

## 详细文档

- [`docs/architecture.md`](docs/architecture.md)：组件分工、挂载路径表、运行流程
- [`docs/security-model.md`](docs/security-model.md)：信任边界、约束模型、已知盲点
- [`docs/persistence.md`](docs/persistence.md)：持久化布局、高风险入口、清理与迁移
- [`docs/extending.md`](docs/extending.md)：新增 MCP / 调整 blocklist / 注入环境变量
- [`docs/verification.md`](docs/verification.md)：本地静态检查与端到端验证脚本

## 验证

`scripts/verify.sh` 拉起完整栈、对放行/阻断/MCP/持久化做断言、再清理。**它会启停容器**，共享环境里别直接跑。
