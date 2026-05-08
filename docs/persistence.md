# 持久化与挂载策略

## 设计目标

sandbox 内的 agent、工具链和第三方代码默认不可信。持久化目录不是安全边界；真正的风险是“不可信进程写入的文件，会不会在下一次启动继续进入执行链”。

当前策略：

- `/home/node` 是 tmpfs，每次启动重建，不作为持久化单元
- 持久化按语义拆成 `/state`、`/cache`、`/logs`、`/tool-bin`
- 容器根文件系统默认 `read_only: true`
- shell 启动骨架由镜像 entrypoint 每次生成，但末尾会 source `/state/shell/*.local` 作为持久化扩展点
- `/tool-bin` 一分为二：`managed/` 由镜像 wrapper 管理（不在 `PATH`），`user/` 存用户/agent 主动安装的可执行物（**在** `PATH`）

## 容器路径

| 容器路径 | 默认宿主路径 | 语义 | 清理策略 |
| --- | --- | --- | --- |
| `/workspace` | `./runtime/workspaces` | 项目源码和工作区 | 按项目自行管理 |
| `/state` | `./runtime/state` | 登录态、session、sqlite、小数据库、普通配置 | 谨慎清理，可审计 |
| `/cache` | tmpfs | npm、XDG、Claude 插件缓存等可重建缓存 | 重启即清空 |
| `/logs` | `./runtime/logs` | 日志 | 可轮转或清空 |
| `/tool-bin/managed` | `./runtime/tool-bin/managed` | 镜像 wrapper 自动下载的二进制（`claude` 等），不在 `PATH` | 高风险入口，重点审计 |
| `/tool-bin/user/bin` | `./runtime/tool-bin/user/bin` | 用户/agent 主动安装的可执行物，**在** `PATH` | 执行链一部分，重点审计 |
| `/tool-bin/user/npm-global` | `./runtime/tool-bin/user/npm-global` | 运行时 `npm i -g` 的安装目录（`NPM_CONFIG_PREFIX`）；`bin/` 在 `PATH` | 执行链一部分，重点审计 |
| `/home/node` | tmpfs | 每次启动生成的 home 视图 | 自动丢弃 |

## Home 视图

entrypoint 会在 tmpfs `/home/node` 中创建固定 symlink：

| Home 路径 | 指向 |
| --- | --- |
| `~/.claude` | `/state/claude` |
| `~/.claude.json` | `/state/claude.json` |
| `~/.codex` | `/state/codex` |
| `~/.config` | `/state/xdg/config` |
| `~/.cache` | `/cache/xdg` |
| `~/.local/share` | `/state/xdg/data` |
| `~/.local/state` | `/state/xdg/state` |
| `~/.npm` | `/cache/npm` |
| `~/.pnpm-store` | `/cache/pnpm-store` |
| `~/.ssh` | `/state/ssh` |
| `~/.gitconfig` | `/state/git/gitconfig` |
| `~/.gitignore_global` | `/state/git/gitignore_global` |
| `~/.memsearch` | `/state/memsearch` |

`XDG_CONFIG_HOME`、`XDG_DATA_HOME`、`XDG_STATE_HOME`、`XDG_CACHE_HOME`、`XDG_RUNTIME_DIR` 也在镜像环境和启动 shell 中设置，规矩应用会自然落到 `/state`、`/cache` 或 tmpfs runtime 目录。`XDG_RUNTIME_DIR` 默认是 `/tmp/xdg-runtime`，不持久化。

## 高风险入口

以下内容会影响后续执行或 agent 行为，宿主机侧应重点审计：

- `/tool-bin/managed`：镜像 wrapper 下载的二进制。**不在** `PATH`，只能通过 `/usr/local/bin/<wrapper>` 显式调用。
- `/tool-bin/user/bin`、`/tool-bin/user/npm-global/bin`：用户/agent 主动安装的可执行物。**在** `PATH`，下次 shell 启动会自动可见，等同执行链。
- `/state/shell/*.local`（`zshrc.local`、`zshenv.local`、`bashrc.local`、`profile.local`）：shell 启动骨架末尾会 source 这些文件，等同 `~/.zshrc`。如果不需要可持久化的 shell 自定义，宿主机侧把它们删掉即可。
- `/state/entrypoints/claude`：Claude hooks、commands、skills、agents、scripts、statusline 等入口。
- `/state/git/gitconfig`：Git alias、include、hooksPath 等配置可能改变命令行为。

Claude 的 `hooks`、`commands`、`skills`、`agents`、`bin`、`scripts` 和 `statusline-command.sh` 通过相对 symlink 从 `/state/claude` 指向 `/state/entrypoints/claude`，保持兼容同时集中审计。使用相对 symlink 是为了让宿主机侧 `runtime/state/...` 和容器内 `/state/...` 都能正常解析。

新增工具不需要改镜像才能新增入口目录映射。可以通过 `AGENT_SANDBOX_ENTRYPOINT_LINKS` 追加映射：

```env
AGENT_SANDBOX_ENTRYPOINT_LINKS=".codex/skills=codex/skills .codex/commands=codex/commands"
```

entrypoint 会拒绝映射 `.zshrc`、`.profile`、`.bashrc`、`.local/bin` 等启动链和 PATH 敏感路径。

## 运行时工具

`claude` 的命令名来自镜像层 `/usr/local/bin/claude` wrapper。wrapper 在需要时把官方二进制下载到 `/tool-bin/managed/claude`，并保存 SHA256 元数据；后续运行前会做本地 checksum 检查，失败则重新安装。

`/tool-bin` 分两个子树，对应不同的信任级别：

- `/tool-bin/managed/`：镜像 wrapper 写入。**不在** `PATH`，调用必须经过 `/usr/local/bin/<wrapper>`，wrapper 负责校验完整性。攻击面：能同时改二进制和 `.sha256` 的攻击者可以绕过校验，但 shell 启动不会自动执行该目录里的内容。
- `/tool-bin/user/bin`、`/tool-bin/user/npm-global/bin`：用户/agent 写入。**在** `PATH`，重启后下一次 shell 即生效。这是把"容器内装的工具持久化"的钩子，代价是它直接进执行链——和 `/state/shell/*.local`、`/state/entrypoints/claude` 同一审计级别。

新增 CLI 的规则：

- 能放进镜像层的 CLI 放进镜像层。
- 用户/agent 在容器内 `npm i -g`、把静态二进制丢进 `/tool-bin/user/bin` 都会持久化并自动进 `PATH`。`pipx` / `cargo install` / `mise` 等工具如需持久化，把对应 `*_BIN_DIR` / `CARGO_HOME` / `MISE_DATA_DIR` 指向 `/tool-bin/user/...`（可在 `/state/shell/zshrc.local` 里写）。
- 镜像 wrapper 自动下载的官方二进制放 `/tool-bin/managed`，不进 `PATH`。
- 配置和 session 放 `/state`，缓存放 `/cache`。
- shell 自定义写在 `/state/shell/*.local`；不要直接修改 `~/.zshrc`，那是每次启动从镜像生成的骨架，会被覆盖。

## 故意不支持

下面这些"容器内变更"按当前安全模型不持久化，需要修改对应镜像并 rebuild：

- `apt install`：sandbox 默认 `read_only: true` + `cap_drop: ALL` + 无 sudo，根文件系统不可写。要新增系统包请改 `sandbox/Dockerfile`。
- `entrypoint` / `install-claude` / `claude` wrapper / `/etc/agent-sandbox/zshrc` 骨架：在镜像层。这是核心执行链入口，故意不放进 `/state`，避免 agent 改一行就改下次启动行为。
- 镜像内置的 `codex` 全局 npm 包：装在 `/usr/local/share/npm-global`，read-only 根文件系统下不可覆盖。运行时升级版本请用 `npm i -g @openai/codex` 装到 `/tool-bin/user/npm-global`，PATH 顺序会让用户层版本优先。

## 清理

清 cache：

```bash
bin/agent-sandbox down
bin/agent-sandbox up
```

清 state：

```bash
find runtime/state -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
```

清运行时工具（同时清掉 wrapper 自动下载的二进制和用户/agent 装的全局包）：

```bash
find runtime/tool-bin -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
```

只清 wrapper 自动下载的部分：

```bash
rm -rf runtime/tool-bin/managed
```

只清用户/agent 装的部分：

```bash
rm -rf runtime/tool-bin/user
```

彻底重置运行态：

```bash
find runtime/logs runtime/state runtime/tool-bin runtime/workspaces -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
```

## 从旧 `runtime/home` 迁移

旧版本把整个 `runtime/home` 挂到 `/home/node`。迁移到新布局：

```bash
scripts/migrate-home-to-state.sh runtime/home
```

脚本只迁移白名单内容：

- Claude / Codex 状态
- 常用 XDG 配置
- Git 配置
- `known_hosts`
- memsearch 状态

脚本不会迁移：

- `.cache`、`.npm`、`.vscode-server`、Go/Bun 工具链等可重建内容
- `.cc-connect`
- `.git-credentials`
- 旧 shell 启动文件到执行链
- 旧 `~/.local/bin` 中的可执行文件
