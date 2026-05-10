# AGENTS.md

写给在这个 sandbox 容器里跑、被授权改这份 repo 自己代码的 agent 看。简称"自举"——你正在编辑构建你自己的代码。本文只覆盖**自举特有的注意点**，通用的项目说明在 [README](README.md) 和 [docs/](docs/)。

## 你看到的目录是什么

容器里你会看到下面几棵树，**它们语义不同，别混着用**：

| 路径 | 是什么 | 写它会怎样 |
| --- | --- | --- |
| `/self` | 你正在编辑的源代码（host 上的 agent-sandbox repo） | 改动直接落到 host repo，下次 host 侧 `bin/agent-sandbox up` 时 docker 会按新代码 rebuild |
| `/workspace` | 普通项目工作区（host: `runtime/workspaces`） | 你日常干活的地方，跟 sandbox 自身无关 |
| `/home/node` | 你（这个容器）的 home（host: `runtime/home`） | 跨重启持久化；`~/.claude/`、`~/.gitconfig` 等会留下 |
| `/state` | 容器运行态（host: `runtime/state`） | shell 扩展、`env.local`、dev-cache 等 |
| `/cache` | tmpfs，重启即清 | 临时缓存 |
| `/logs` | 日志（host: `runtime/logs`） | |
| `/tool-bin/managed` `/tool-bin/user` | 持久化二进制 | `managed` 不在 PATH，`user` 在 PATH |

`/self/runtime/` 这条路径在容器里**确实可见**，但它跟 `/state`、`/home/node`、`/workspace` 是同一份 host 数据。在 `/self` 下编辑代码时**当作它不存在**——它只是因为 `/self` 是 host repo 整体挂载的副作用，不是你该编辑的对象。

## 这次改动该不该改

改 `/self` 之前先想：**这个改动是镜像层的，还是运行时层的？**

- **镜像层**（`sandbox/`、`proxy/`、`mcp-gateway/`、`compose.yaml`、`compose.simple.yaml`、`compose.self.yaml`）：改完后必须 host 侧 `bin/agent-sandbox down && up`，docker rebuild 镜像，**当前正在运行的你不会立刻反映新改动**。你**没有 docker**，不能自己 rebuild——必须留给 host 用户。
- **运行时层**（`/state/shell/*.local`、`/state/env.local`、`~/.claude/...`、`/tool-bin/user/...`）：改完下次 shell 启动即生效，不需要 rebuild。但这些**不在 `/self` 里**，不是 git-tracked，是给当前实例的本地配置。
- **脚本/文档层**（`bin/`、`scripts/`、`docs/`、`README.md`、`AGENTS.md`、`.github/`）：改完 git commit + push 即可，CI 验证；不需要 rebuild。

## 你能做的验证（很少）

你**没有 docker**，sandbox 内不能 build 镜像、不能跑 `scripts/verify.sh`、不能 `docker compose config -q`。你能做的是：

- **bash 语法检查**：`bash -n bin/agent-sandbox`、`bash -n scripts/verify.sh`、`sh -n sandbox/files/entrypoint`
- **dockerfile 静态阅读**：纯人眼 review
- **小段逻辑跑 stub**：用 mock 二进制（如 fake docker）模拟个别 case，不能验整体

剩下交给 host：host 上 `bin/agent-sandbox down && up` rebuild 验启动；`scripts/verify.sh` 跑端到端断言（CI 也会跑）。**不要假装跑过实测**——明确告诉用户你只做了静态检查、剩下需要 host 验证。

## 不能干的事 / 真正会爆炸的操作

- **`rm -rf /self/runtime/`** 等于 `rm -rf /state /home/node /tool-bin /workspace`——你正在用的所有运行态。**当场炸**。
- **改 `sandbox/files/entrypoint` 写入语法错误**：下次 sandbox 启动直接退出，host 用户没法进容器修，得手动改 host repo 文件后 rebuild。提交前 `sh -n sandbox/files/entrypoint`。
- **改 `proxy/squid.conf` 写错语法**：proxy 起不来，sandbox 出网全废、healthcheck 不过、autoheal restart 死循环。
- **改 `compose.yaml` 让 `service_healthy` 依赖一个永远 unhealthy 的服务**：sandbox 永远起不来。
- **改 `.github/workflows/ci.yml` 把 `verify.sh` 跳过**：CI 绿但代码可能是坏的。

## 提交习惯

- conventional commit（`feat:` / `fix:` / `chore:` / `docs:`）。
- 一条 commit 一个 scope；自举改动里如果同时碰了运行时配置（`/state/...`）和源代码（`/self/...`），只 commit 后者，前者属于本机配置。
- `.gitignore` 已经把 `runtime/*` 排掉，`git add -A` 在 `/self` 里不会污染——但仍然 review `git status` 确认。
- push 前不要把 secrets / API key 写进 `.env.example` 或代码（host 上的 `.env` 不在 git 里，但 `.env.example` 在）。
- 推不推 由 host 用户决定，不要默认 `git push`，问一下。

## 已有的不变量，别破坏

- shell rc（`~/.zshrc/.zshenv/.profile/.bashrc`）每次启动从镜像层覆盖。这是防"agent 自我增殖"的核心机制。任何让 shell rc 内容跨重启存活的改动都是 regression。
- `/tool-bin/managed` 不在 PATH（必须经 `/usr/local/bin/<wrapper>`）；`/tool-bin/user` 在 PATH（用户 / agent 装的）。混淆这两个会让"由谁管理"的边界塌掉。
- proxy 是默认放行 + blocklist。改 squid.conf / blocklist 不要默默改成 default-deny，那会破坏 sandbox 的开发体验。
- mcp-gateway 持有 GitHub PAT；sandbox 不持有。任何让 sandbox 拿到 PAT 的改动都是降级安全模型。
- autoheal 持 docker socket 的边界已在 [`docs/security-model.md`](docs/security-model.md) 写明；不要扩 autoheal 的能力（不要给它装额外脚本、不要让它接外部网络）。

## 跟 host 用户沟通

你跟 host 是异步协作。每次自举：

1. 说清楚你打算改什么、改哪个文件、为什么。
2. 改完列改动文件 + 关键 diff 段。
3. 明确告诉 host："我没跑 `verify.sh`，需要你 `down && up` 验证 / 跑 CI"。
4. 不主动 commit / push 除非用户说了。

## 相关文档

- [`README.md`](README.md)：使用指南，含自举开关
- [`docs/architecture.md`](docs/architecture.md)：组件分工
- [`docs/security-model.md`](docs/security-model.md)：信任边界
- [`docs/persistence.md`](docs/persistence.md)：持久化布局、高风险入口
- [`docs/extending.md`](docs/extending.md)：新增 MCP / 注入环境变量
- [`docs/verification.md`](docs/verification.md)：验证脚本断言清单
