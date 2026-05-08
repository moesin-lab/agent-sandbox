# 持久化与挂载策略

## 设计目标

sandbox 内的 agent、工具链和第三方代码默认不可信。持久化目录不是安全边界；真正的风险是“不可信进程写入的文件，会不会在下一次启动继续进入执行链”。

当前策略：

- `/home/node` 是 tmpfs，每次启动重建，不作为持久化单元
- 持久化按语义拆成 `/state`、`/cache`、`/logs`、`/tool-bin`
- 容器根文件系统默认 `read_only: true`
- shell 启动文件由镜像 entrypoint 每次生成，不从持久化目录自动 source
- 可写的运行时下载二进制放在 `/tool-bin`，不加入 `PATH`

## 容器路径

| 容器路径 | 默认宿主路径 | 语义 | 清理策略 |
| --- | --- | --- | --- |
| `/workspace` | `./runtime/workspaces` | 项目源码和工作区 | 按项目自行管理 |
| `/state` | `./runtime/state` | 登录态、session、sqlite、小数据库、普通配置 | 谨慎清理，可审计 |
| `/cache` | tmpfs | npm、XDG、Claude 插件缓存等可重建缓存 | 重启即清空 |
| `/logs` | `./runtime/logs` | 日志 | 可轮转或清空 |
| `/tool-bin` | `./runtime/tool-bin` | 运行时下载的可执行物 | 高风险入口，重点审计 |
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

- `/tool-bin`：运行时下载的可执行文件。该目录不在默认 `PATH` 中。
- `/state/entrypoints/claude`：Claude hooks、commands、skills、agents、scripts、statusline 等入口。
- `/state/git/gitconfig`：Git alias、include、hooksPath 等配置可能改变命令行为。

Claude 的 `hooks`、`commands`、`skills`、`agents`、`bin`、`scripts` 和 `statusline-command.sh` 通过相对 symlink 从 `/state/claude` 指向 `/state/entrypoints/claude`，保持兼容同时集中审计。使用相对 symlink 是为了让宿主机侧 `runtime/state/...` 和容器内 `/state/...` 都能正常解析。

新增工具不需要改镜像才能新增入口目录映射。可以通过 `AGENT_SANDBOX_ENTRYPOINT_LINKS` 追加映射：

```env
AGENT_SANDBOX_ENTRYPOINT_LINKS=".codex/skills=codex/skills .codex/commands=codex/commands"
```

entrypoint 会拒绝映射 `.zshrc`、`.profile`、`.bashrc`、`.local/bin` 等启动链和 PATH 敏感路径。

## 运行时工具

`claude` 的命令名来自镜像层 `/usr/local/bin/claude` wrapper。wrapper 在需要时把官方二进制下载到 `/tool-bin/claude`，并保存 SHA256 元数据；后续运行前会做本地 checksum 检查，失败则重新安装。`~/.local/bin` 只是 tmpfs home 里的普通目录，不指向 `/tool-bin`，也不在默认 `PATH` 中。

限制：

- `/tool-bin` 仍是可写持久化目录，checksum 元数据也在同一信任域内，不能抵御已经能同时修改二进制和元数据的攻击者。
- 安全收益来自隔离和可审计：该目录不在 `PATH`，不会被 shell 启动自动执行，宿主机可以单独清理或检查。

新增 CLI 的规则：

- 能放进镜像层的 CLI 放进镜像层。
- 需要运行时下载的 CLI 放 `/tool-bin`，通过镜像层 wrapper 调用，不把 `/tool-bin` 加进 `PATH`。
- 配置和 session 放 `/state`，缓存放 `/cache`。
- 不要把 shell rc、profile、env 文件从 `/state` 自动 source。

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

清运行时工具：

```bash
find runtime/tool-bin -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
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
