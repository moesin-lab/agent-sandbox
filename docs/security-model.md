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

GitHub PAT 只注入 `mcp-gateway`。`sandbox` 与 `proxy` 都不应持有这个凭据，对 GitHub 的程序化访问只能走 mcp-gateway 暴露的 named server 路径。

## 当前约束模型

- sandbox 通过 `network_mode: "service:proxy"` 共享 proxy 的 network namespace；proxy 容器在 `nat OUTPUT` 链对 80/443 做 `REDIRECT` 到本地 Squid，应用感知不到代理存在
- Squid 走**默认放行 + 黑名单**：未在 `blocklist.txt` 中显式列出的目的全部放行；HTTP 由 `http_access deny` 拒绝，HTTPS 在 SslBump1 peek 到匹配 SNI 后 terminate，其余 splice 直通
- 不做 MITM，sandbox 内不需要任何 CA
- runtime 数据默认从仓库管理目录挂载，也可以用 `.env` 将 workspace/state/cache/logs/tool-bin 指向自定义 host 路径；sandbox 容器以 `node` 用户运行，默认关闭 passwordless sudo，并启用只读根文件系统、`no-new-privileges`、`cap_drop: ALL`、PID/CPU/内存上限
- `/home/node` 是 tmpfs，不再作为持久化 home；entrypoint 每次启动生成 shell rc/profile，并通过 XDG 环境变量和 symlink 把常见状态目录导向 `/state` 或 `/cache`
- `/tool-bin` 用于运行时下载的可执行物，不在默认 `PATH` 中；镜像层 wrapper 负责调用这些工具
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
- **运行时工具目录仍可被投毒**。`/tool-bin` 不在默认 `PATH` 且由镜像层 wrapper 进入，但它仍是可写持久化目录；本地 checksum 只能发现部分损坏或简单替换，不能抵御能同时改二进制和元数据的攻击者。需要彻底恢复时清空 `runtime/tool-bin` 重新下载。
- **持久化配置仍能影响工具行为**。例如 `/state/git/gitconfig`、`/state/entrypoints/claude` 会改变后续 Git/Claude 行为；这些目录被集中放置是为了便于宿主机审计，不代表它们可信。
- **镜像构建仍会直接出网**。`codex`、系统包和其它 build 依赖的获取仍通过宿主机网络，不经过本仓库的代理链路；`claude` 的运行时安装会经过 proxy 的透明代理链路。

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
- 定期审计 `runtime/state/entrypoints`、`runtime/tool-bin` 和 `runtime/state/git`
