# 安全模型

## 目标

让"最安全的路径"同时也是"最顺手的路径"：

- 敏感能力优先通过 MCP 服务暴露，而不是放任 sandbox 自己 `curl`
- 常规出网受透明代理 + blocklist 约束
- 运行态数据统一落在仓库管理的 `runtime/` 目录里，并按 state/cache/logs/tool-bin 拆分

## 信任边界

| 边界 | 信任级别 | 持有的凭据 |
| --- | --- | --- |
| Host | 可信，持有源码与本地凭据 | 任意 host shell 环境变量 |
| sandbox | 低于 host，仅可写少数 runtime 挂载和 tmpfs 目录 | `ANTHROPIC_API_KEY`、`OPENAI_API_KEY`（可选透传），oauth 凭据落 `runtime/state` |
| proxy | 中性，仅做出网过滤；持有 `NET_ADMIN` cap 用于 iptables | 无 |
| mcp-gateway | 持有面向受控外部 API 的高权限凭据 | `GITHUB_PERSONAL_ACCESS_TOKEN` |
| autoheal（仅默认拓扑） | 持有 host docker socket（实质 host root），用于 `docker restart` unhealthy 容器 | 无（仅 socket 通路） |

GitHub PAT 只注入 `mcp-gateway`。`sandbox` 与 `proxy` 都不应持有这个凭据，对 GitHub 的程序化访问只能走 mcp-gateway 暴露的 named server 路径。

`bin/agent-sandbox up --self` 会把 host 上的 agent-sandbox repo 挂到 sandbox 的 `/self`（自举场景）。这条挂载会刻意遮掉三处属于 enforcement 侧的内容，避免 sandbox 在 `/self` 下读到或改写自己运行所依赖的边界配置（详见 `compose.self.yaml`）：

| 路径 | 处理 | 原因 |
| --- | --- | --- |
| `/self/.env` | bind `/dev/null:ro` | 保护 `GITHUB_PERSONAL_ACCESS_TOKEN` 等只该给 mcp-gateway 看的密钥 |
| `/self/config/proxy-rules/` | tmpfs read_only | 防止 sandbox 改写 blocklist 后通过 proxy 重启自动生效 |
| `/self/config/mcp-gateway/` | tmpfs read_only | 防止 sandbox 在 servers.json 加新 named server 或改凭据路径 |

## 当前约束模型

- sandbox 通过 `network_mode: "service:proxy"` 共享 proxy 的 network namespace；proxy 容器在 `nat OUTPUT` 链对 80/443 做 `REDIRECT` 到本地 Squid，应用感知不到代理存在
- Squid 走**默认放行 + 黑名单**：未在 `blocklist.txt` 中显式列出的目的全部放行；HTTP 由 `http_access deny` 拒绝，HTTPS 在 SslBump1 peek 到匹配 SNI 后 terminate，其余 splice 直通
- 不做 MITM，sandbox 内不需要任何 CA
- runtime 数据默认从仓库管理目录挂载，也可以用 `.env` 将 workspace/home/state/cache/logs/tool-bin 指向自定义 host 路径；sandbox 容器以 `node` 用户运行，默认关闭 passwordless sudo，并启用只读根文件系统、`no-new-privileges`、`cap_drop: ALL`、PID/CPU/内存上限
- `/home/node` 是 host bind mount → `runtime/home/`，所以 `~/.<tool>` 默认持久化；entrypoint 每次启动**强制覆盖** shell rc/profile 骨架（agent 写入 `~/.zshrc` 等不会跨重启存活），并按 `home-ephemeral.list` 把已知缓存 / IDE server / nix-portable store 转到 `/cache/`（tmpfs）或 `/state/dev-cache/`（持久化但可整目录删）
- `/tool-bin` 拆成两个子树：`managed/`（镜像 wrapper 自动下载，不在 PATH，必须经 `/usr/local/bin/<wrapper>` 调用）和 `user/{bin,npm-global/bin}`（用户/agent 主动安装，**在** PATH，重启后下次 shell 即生效）
- GitHub MCP 通过 mcp-gateway 内置的 named server 暴露在 `/servers/github/...`，端口 8080 不在 NAT 规则里
- 默认 `blocklist.txt` 列入 `api.github.com` 与 `uploads.github.com`，迫使对 GitHub 的程序化访问只能走 mcp-gateway

## 已知盲点

这套实现不能宣称对所有绕过手法都具备完整隔离能力：

- **隔离强度依赖 blocklist 覆盖度**。默认放行意味着任何未列入黑名单的目的都通；需要严格收口的场景应改为 default-deny + allowlist
- **仅 SNI 检查**。无法识别 ESNI / ECH 流量；也无法防止以 IP 直连访问敏感目标（dstdomain 失效场景）
- **IPv6 未拦截**。当前依赖 Docker 默认网络无 IPv6；启用 IPv6 需要补 `ip6tables` 规则
- **uid 豁免假设**。iptables 按 uid 豁免 squid 自身，假定 sandbox 内不会出现以 `proxy` uid 运行的进程
- **挂载路径即信任入口**。自定义 workspace/state/cache/logs/tool-bin 路径会暴露给 sandbox 读写；不要把 host 的密钥目录、浏览器资料、云凭据目录或 Docker socket 放进这些路径。
- **sudo 可被显式打开**。`ENABLE_PASSWORDLESS_SUDO=1` 且 `AGENT_SANDBOX_NO_NEW_PRIVILEGES=false` 适合可信开发会话，但会让 agent 能升到容器 root；跑陌生代码时应保持默认关闭。
- **运行时工具目录仍可被投毒**。`/tool-bin/managed` 不在默认 `PATH` 且由镜像层 wrapper 进入，但它仍是可写持久化目录；本地 checksum 只能发现部分损坏或简单替换，不能抵御能同时改二进制和元数据的攻击者。需要彻底恢复时清空 `runtime/tool-bin/managed` 重新下载。
- **`/tool-bin/user` 直接进入执行链**。这是为了让容器内 `npm i -g`、用户拖入静态二进制等操作能在重启后生效；agent 写入这里的任何可执行物，下次 shell 启动会自动 PATH 可见。该子目录的审计级别与 `/state/shell/*.local`、`/state/entrypoints/claude` 等同。
- **持久化配置仍能影响工具行为**。例如 `~/.gitconfig`（位于 `runtime/home/.gitconfig`）、`~/.claude/{hooks,commands,skills,...}`、`/state/shell/*.local`、`/state/home-ephemeral.local` 都会改变后续 Git/Claude/shell 行为；home bind mount 让这些直接落到 `runtime/home/`，便于 host 侧审计，但同样不代表它们可信。entrypoint 拒绝把 `.zshrc/.zshenv/.profile/.bashrc/.bash_profile/.local/bin` 等启动链路径通过 ephemeral list 重映射，且每次启动覆盖 shell rc 骨架，所以 home 持久化不会让 `~/.zshrc` 自我增殖。
- **镜像构建仍会直接出网**。`codex`、系统包和其它 build 依赖的获取仍通过宿主机网络，不经过本仓库的代理链路；`claude` 的运行时安装会经过 proxy 的透明代理链路。
- **autoheal 持有 docker socket**。默认拓扑加了 `willfarrell/autoheal` sidecar，根据 `proxy` / `mcp-gateway` 的 healthcheck 自动重启 unhealthy 容器。这意味着 autoheal 容器一旦被攻陷等于 host root。缓解：image tag 锁版本（`willfarrell/autoheal:1.2.0`）、`network_mode: "none"` 切断入站、`AUTOHEAL_CONTAINER_LABEL=autoheal` 只看显式标记的容器。简洁拓扑（`compose.simple.yaml`）不启用 autoheal。如果你的威胁模型不接受任何持 docker socket 的容器，去掉默认拓扑里的 `autoheal` 服务、改用 host 侧 cron。

## 主要针对的风险

- sandbox 意外直连 `api.github.com` 这类敏感 API
- Agent 在 shell 里直接 `curl` 绕开本该走的 MCP 路径
- 运行态数据散落到随意的宿主机目录
- Agent 工具自我增殖时缺少审计入口
- 挂载投毒：不可信进程写入持久化 home、shell rc 或 PATH 目录，并在下一次启动自动生效

## 建议的使用习惯

- 新的敏感集成优先做成 MCP 服务，而不是开放 proxy 出口
- proxy blocklist 显式列出需要被收口的目的；其余视为放行
- 视 `scripts/verify.sh` 为会修改环境的操作（启停容器）；共享环境里别直接跑
- 定期审计高风险持久化入口：`runtime/home/.claude/{hooks,commands,skills,agents,bin,scripts}`、`runtime/home/.gitconfig`、`runtime/home/.mails/config.json`、`runtime/state/shell/*.local`、`runtime/state/env.local`、`runtime/state/home-ephemeral.local`、`runtime/tool-bin/{managed,user}`
