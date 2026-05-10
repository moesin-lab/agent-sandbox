# 持久化与挂载策略

## 设计目标

sandbox 内的 agent、工具链和第三方代码默认不可信。持久化目录不是安全边界；真正的风险是“不可信进程写入的文件，会不会在下一次启动继续进入执行链”。

当前策略：

- `/home/node` 是宿主机 bind mount → `runtime/home/`。任何工具往 `~/.<name>` 写东西默认持久化，无需在 entrypoint 注册。
- 已知"垃圾大户"（缓存、IDE-server payload、nix-portable store 等）由 entrypoint 启动时 symlink 转走，让 host 侧 `runtime/home/` 保持干净。
- 容器根文件系统默认 `read_only: true`。
- shell 启动文件（`.zshrc`、`.zshenv`、`.profile`、`.bashrc`）由镜像 entrypoint **每次启动强制覆盖**，agent 在 `~/.zshrc` 里写的任何东西都会在 restart 时被丢弃；shell 自定义只能写 `/state/shell/*.local`。
- `/state` 仅承载结构性持久化项：shell 扩展、env.local、dev-cache、用户的 ephemeral 扩展。其余配置/状态都直接落 `~/`。

## 容器路径

| 容器路径 | 默认宿主路径 | 语义 | 清理策略 |
| --- | --- | --- | --- |
| `/workspace` | `./runtime/workspaces` | 项目源码和工作区 | 按项目自行管理 |
| `/home/node` | `./runtime/home` | 用户 home，默认全部持久化（除 ephemeral list 转走的子路径） | 谨慎清理 |
| `/state` | `./runtime/state` | shell 扩展、env vars、dev-cache（IDE server / nix-portable 等） | 谨慎清理 |
| `/cache` | tmpfs | npm、XDG cache 等可重建缓存 | 重启即清空 |
| `/logs` | `./runtime/logs` | 日志 | 可轮转或清空 |
| `/tool-bin/managed` | `./runtime/tool-bin/managed` | 镜像 wrapper 自动下载的二进制（`claude` 等），不在 `PATH` | 高风险入口，重点审计 |
| `/tool-bin/user/bin` | `./runtime/tool-bin/user/bin` | 用户/agent 主动安装的可执行物，**在** `PATH` | 执行链一部分，重点审计 |
| `/tool-bin/user/npm-global` | `./runtime/tool-bin/user/npm-global` | 运行时 `npm i -g` 的安装目录（`NPM_CONFIG_PREFIX`）；`bin/` 在 `PATH` | 执行链一部分，重点审计 |

## Home 持久化模型

`/home/node` 是 bind mount，所以：

- agent 在容器内 `mkdir ~/.opencode && cp config.toml ~/.opencode/` 之类的操作**自然持久化**，不需要在镜像里登记
- host 侧直接看 `runtime/home/.opencode/...`，可审计、可备份

为了不让 home 被缓存和 IDE server payload 占满，entrypoint 在每次启动时按 **denylist** 把以下子路径替换为 symlink：

| Home 路径 | 指向 | 性质 |
| --- | --- | --- |
| `~/.cache` | `/cache/xdg` (tmpfs) | 真垃圾，重启即清 |
| `~/.npm` | `/cache/npm` (tmpfs) | 真垃圾 |
| `~/.pnpm-store` | `/cache/pnpm-store` (tmpfs) | 真垃圾 |
| `~/.local/share/Trash` | `/tmp/trash` (tmpfs) | 真垃圾 |
| `~/.claude/cache` | `/cache/claude` (tmpfs) | 真垃圾 |
| `~/.vscode-server` | `/state/dev-cache/vscode-server` | 持久化但可整目录删 |
| `~/.cursor-server` | `/state/dev-cache/cursor-server` | 持久化但可整目录删 |
| `~/.windsurf-server` | `/state/dev-cache/windsurf-server` | 持久化但可整目录删 |
| `~/.nix-portable` | `/state/dev-cache/nix-portable` | 持久化但可整目录删 |

这份默认列表来自镜像内 `/etc/agent-sandbox/home-ephemeral.list`。

### 用户扩展

发现新的"垃圾大户"，往 `/state/home-ephemeral.local` 追加几行就行（同一格式）：

```
.continue/cache  /cache/continue
.docker          /state/dev-cache/docker
```

下一次启动 entrypoint 会合并默认 list 和用户 list 处理。受保护的路径（`.zshrc`、`.zshenv`、`.profile`、`.bashrc`、`.bash_profile`、`.local/bin`）以及包含 `..` 的路径会被 entrypoint 拒绝。

### 启动时的迁移行为

如果 home 里某个路径已经是真目录（比如旧版 home 持久化前的 `runtime/home/.cache/`），entrypoint 会先把内容 cp 到 target，再 rm 原目录、建立 symlink。失败会 emit warning 并保留原目录，避免数据丢失。

## /state 结构

home 持久化后，`/state` 只剩少量结构化项：

```
runtime/state/
├── shell/
│   ├── zshrc.local        # 持久化 shell 自定义（zsh 交互）
│   ├── zshenv.local       # 持久化 env，所有 zsh 启动时
│   ├── profile.local      # 持久化 env，POSIX login shell
│   └── bashrc.local       # 持久化 shell 自定义（bash 交互）
├── env.local              # 持久化 KEY=value 环境变量
├── home-ephemeral.local   # 用户扩展的 ephemeral list（可选）
└── dev-cache/             # IDE server / nix-portable store 等"持久化但可丢"的池
    ├── vscode-server/
    ├── cursor-server/
    └── nix-portable/
```

旧版本的 `/state/{claude,codex,xdg/{config,data,state},git,ssh,memsearch,entrypoints}` 全部退役。容器**首次启动**会自动检测旧路径，把内容 cp 到 home 对应位置（`/state/claude/*` → `~/.claude/*`、`/state/entrypoints/claude/<sub>` → `~/.claude/<sub>` 等），并把原路径改名为 `_migrated_<timestamp>` 留痕。确认无误后 host 侧自行清理这些 archive。

## 高风险入口

以下内容会影响后续执行或 agent 行为，宿主机侧应重点审计：

- `/tool-bin/managed`：镜像 wrapper 下载的二进制。**不在** `PATH`，只能通过 `/usr/local/bin/<wrapper>` 显式调用。
- `/tool-bin/user/bin`、`/tool-bin/user/npm-global/bin`：用户/agent 主动安装的可执行物。**在** `PATH`，下次 shell 启动会自动可见，等同执行链。
- `/state/shell/*.local`：shell 启动骨架末尾会 source 这些文件，等同 `~/.zshrc`。
- `/state/env.local`：每行 `KEY=value` 的持久化环境变量；shell 启动时由 `/etc/agent-sandbox/env-loader.sh` 解析并 export。值不做 shell 求值（`$VAR` / `$(cmd)` 原样保留），保留键 `PATH`、`HOME`、`SHELL`、`USER`、`UID`、`LOGNAME`、`PWD`、`OLDPWD` 直接拒绝以保护执行链。
- `/state/home-ephemeral.local`：用户扩展的 ephemeral list；entrypoint 拒绝把保留路径（shell rc / .local/bin）转成 symlink，所以这条文件不能被用来重写启动链，但仍然能通过 symlink 把 home 里某个目录指到任意持久化位置——审计 list 时确认 target 可信。
- `~/.claude/{hooks,commands,skills,agents,bin,scripts,statusline-command.sh}`：旧版本通过 `/state/entrypoints/claude/` 集中管理；现在直接落在 `runtime/home/.claude/` 下。
- `~/.gitconfig`：Git alias、include、hooksPath 等配置可能改变命令行为。
- `~/.mails/config.json`：mails CLI 的 mailbox + `mk_...` API key（hosted mails.dev 或自建 Worker 凭据）；任何能读 home 的角色都能拿到该 key 发邮件。

## 运行时工具

`claude` 的命令名来自镜像层 `/usr/local/bin/claude` wrapper。wrapper 在需要时把官方二进制下载到 `/tool-bin/managed/claude`，并保存 SHA256 元数据；后续运行前会做本地 checksum 检查，失败则重新安装。

`/tool-bin` 分两个子树，对应不同的信任级别：

- `/tool-bin/managed/`：镜像 wrapper 写入。**不在** `PATH`，调用必须经过 `/usr/local/bin/<wrapper>`。
- `/tool-bin/user/bin`、`/tool-bin/user/npm-global/bin`：用户/agent 写入。**在** `PATH`，重启后下一次 shell 即生效。

新增 CLI 的规则：

- 能放进镜像层的 CLI 放进镜像层。
- 用户/agent 在容器内 `npm i -g`、把静态二进制丢进 `/tool-bin/user/bin` 都会持久化并自动进 `PATH`。
- 镜像 wrapper 自动下载的官方二进制放 `/tool-bin/managed`，不进 `PATH`。
- 配置和工具状态默认走 `~/.<tool>/`，由 home bind mount 自动持久化。
- shell 自定义写在 `/state/shell/*.local`；不要直接修改 `~/.zshrc`，那是每次启动从镜像生成的骨架，会被覆盖。

## 系统包：nix-portable 路径

容器仍然 `read_only: true` + `cap_drop: ALL`，**`apt install` 物理上做不了**。不过镜像里预装了 [`nix-portable`](https://github.com/DavHau/nix-portable)（一个静态二进制，不需要 root / 不需要 daemon），用来在沙盒里装 nixpkgs 的任意系统工具。

```bash
nix-portable nix-env -iA nixpkgs.ffmpeg
nix-portable nix-env -iA nixpkgs.imagemagick nixpkgs.jq
nix-portable nix shell nixpkgs#ripgrep -- rg --version
```

store 落在 `~/.nix-portable/`，由 ephemeral list 转到 `/state/dev-cache/nix-portable/` 持久化。**第一次**调用会做一次 nix store bootstrap（比较慢、需要联网，几百 MB），之后增量。

如果某个工具一定需要装到 `/usr/...`（极少见，例如某些 systemd 单元），仍然要改 `sandbox/Dockerfile` 并 rebuild。

## 故意不支持

- `apt install` 直接生效：read-only root + 没 sudo，物理上做不了。改 `sandbox/Dockerfile` rebuild，或走上面的 nix-portable。
- `entrypoint` / `install-claude` / `claude` wrapper / `/etc/agent-sandbox/zshrc` 骨架等执行链入口在镜像层，故意不放进 `/state` 或 home，避免 agent 改一行就改下次启动行为。
- 镜像内置的 `codex` 全局 npm 包：装在 `/usr/local/share/npm-global`，read-only 根文件系统下不可覆盖。运行时升级版本请用 `npm i -g @openai/codex` 装到 `/tool-bin/user/npm-global`，PATH 顺序会让用户层版本优先。

## 清理

清 cache：

```bash
bin/agent-sandbox down
bin/agent-sandbox up
```

清 home（连同 agent 写入的所有配置/工具数据）：

```bash
find runtime/home -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
```

清 IDE server / nix-portable store（不影响 home 主体）：

```bash
rm -rf runtime/state/dev-cache
```

清 state 结构项：

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
find runtime/home runtime/logs runtime/state runtime/tool-bin runtime/workspaces \
    -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
```

## 从旧布局迁移

旧版本（home tmpfs + `/state/{claude,codex,xdg,...}`）的数据**不需要手动迁移**。新 entrypoint 在容器首次启动时检测旧路径，自动 cp 到 `runtime/home/` 对应位置，并把原路径改名为 `_migrated_<timestamp>`。确认数据完整后 host 侧自行清理 archive。

更早版本（`runtime/home` 直接 mount 整个 home 的版本）也兼容：把 `runtime/home/` 直接保留即可，新架构会继续在它上面跑。

