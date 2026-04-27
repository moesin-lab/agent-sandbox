# 安全模型

## 目标

让"最安全的路径"同时也是"最顺手的路径"：

- 敏感能力优先通过 MCP 服务暴露，而不是放任 sandbox 自己 `curl`
- 常规出网受透明代理 + blocklist 约束
- 运行态数据统一落在仓库管理的 `runtime/` 目录里

## 信任边界

| 边界 | 信任级别 | 持有的凭据 |
| --- | --- | --- |
| Host | 可信，持有源码与本地凭据 | 任意 host shell 环境变量 |
| sandbox | 低于 host，仅可写挂载进来的 runtime 目录 | `ANTHROPIC_API_KEY`、`OPENAI_API_KEY`（可选），`GITHUB_TOKEN`（可选，仅给 git CLI），oauth 凭据落 `runtime/home` |
| proxy | 中性，仅做出网过滤；持有 `NET_ADMIN` cap 用于 iptables | 无 |
| mcp-gateway | 持有面向高权限 GitHub API 的凭据 | `GITHUB_PERSONAL_ACCESS_TOKEN` |

GitHub 凭据按用途分两层：

- `GITHUB_PERSONAL_ACCESS_TOKEN` → **只**注入 `mcp-gateway`，用于 GitHub REST/GraphQL 高权限操作（issue / PR / org / admin）
- `GITHUB_TOKEN` → 注入 `sandbox`，仅供容器内 `git clone / pull / push` 使用；推荐使用 fine-grained PAT 把 scope 限到具体 repo。Sandbox 镜像里 `/etc/gitconfig` 把它挂在 `https://github.com` 前缀的 credential helper 上，自动注入

两个变量可以填同一个 PAT，但那意味着主动放弃这层隔离。在 `compose.yaml` 里以无 `=` 形式列出，未设置则不进容器（git 会以匿名方式失败，触发清晰的认证错误）。

## 当前约束模型

- sandbox 通过 `network_mode: "service:proxy"` 共享 proxy 的 network namespace；proxy 容器在 `nat OUTPUT` 链对 80/443 做 `REDIRECT` 到本地 Squid，应用感知不到代理存在
- Squid 走**默认放行 + 黑名单**：未在 `blocklist.txt` 中显式列出的目的全部放行；HTTP 由 `http_access deny` 拒绝，HTTPS 在 SslBump1 peek 到匹配 SNI 后 terminate，其余 splice 直通
- 不做 MITM，sandbox 内不需要任何 CA
- runtime 数据统一从仓库管理目录挂载；sandbox 容器以 `node` 用户运行
- GitHub MCP 通过 mcp-gateway 内置的 named server 暴露在 `/servers/github/...`，端口 8080 不在 NAT 规则里
- 默认 `blocklist.txt` 列入 `api.github.com` 与 `uploads.github.com`，迫使对 GitHub 的**程序化 API 访问**只能走 mcp-gateway。`github.com` 自身不在 blocklist 里，sandbox 内的 `git` CLI 经透明代理直连 github.com 完成 git smart-HTTPS（clone / pull / push）

## 已知盲点

这套实现不能宣称对所有绕过手法都具备完整隔离能力：

- **隔离强度依赖 blocklist 覆盖度**。默认放行意味着任何未列入黑名单的目的都通；需要严格收口的场景应改为 default-deny + allowlist
- **仅 SNI 检查**。无法识别 ESNI / ECH 流量；也无法防止以 IP 直连访问敏感目标（dstdomain 失效场景）
- **IPv6 未拦截**。当前依赖 Docker 默认网络无 IPv6；启用 IPv6 需要补 `ip6tables` 规则
- **uid 豁免假设**。iptables 按 uid 豁免 squid 自身，假定 sandbox 内不会出现以 `proxy` uid 运行的进程
- **build 时下载**。claude / codex 的 build 时获取通过宿主机网络，不经过本仓库的代理链路

## 主要针对的风险

- sandbox 意外直连 `api.github.com` 这类敏感 API
- Agent 在 shell 里直接 `curl` 绕开本该走的 MCP 路径
- 运行态数据散落到随意的宿主机目录
- Agent 工具自我增殖时缺少审计入口

## 建议的使用习惯

- 新的敏感集成优先做成 MCP 服务，而不是开放 proxy 出口
- proxy blocklist 显式列出需要被收口的目的；其余视为放行
- 视 `scripts/verify.sh` 为会修改环境的操作（启停容器）；共享环境里别直接跑
