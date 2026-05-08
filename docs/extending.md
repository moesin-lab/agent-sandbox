# 扩展指南

## 新增一个 MCP 服务

1. 把新的 stdio MCP server 预装进 `mcp-gateway/Dockerfile`（或基于 multi-stage `COPY --from=...` 拷过来）
2. 在 `config/mcp-gateway/servers.json` 里新增一个 named server，约定 `command` / `args` / `transportType`
3. 路径约定：`http://mcp-gateway:8080/servers/<name>/...`，不要让 sandbox 直接走外网到这个能力
4. 如果服务需要新 secret，**只**注入 `mcp-gateway` 容器，不要放进 sandbox 或 proxy
5. 在 `docs/security-model.md` 或服务专属文档里写清楚它的用途、凭据边界、信任边界

MCP 服务应该尽量窄。把多个 stdio server 收口在 mcp-gateway 的 named server 配置里，比继续在 compose 里平铺容器更符合本仓库的默认路径。

## 调整代理黑名单

代理走默认放行 + 黑名单语义：未列入 `config/proxy-rules/blocklist.txt` 的目的，HTTP 与 HTTPS 都直接放行；列入的目的，HTTP 由 `http_access deny` 拒绝，HTTPS 在 `SslBump1` peek 到匹配 SNI 后 terminate。

修改 `blocklist.txt` 后跑一次 `scripts/verify.sh`，确认放行链路仍然通、新加入的目的仍然失败。

Squid 的 `dstdomain` 与 `ssl::server_name` 都支持前导点匹配子域，例如 `.example.com` 同时拦截 `example.com` 和任意子域。

## 给 sandbox 注入新的环境变量

两条路径，按变量来源选：

**1. 来自宿主机环境（API key 等敏感凭据）** — 在 `compose.yaml` 的 `sandbox.environment` 列表里追加变量名（不带 `=`），Docker compose 会从 host shell 读取并透传，host 上未设置的不会出现在容器里。该路径需要 recreate sandbox 容器（`bin/agent-sandbox down && up`），但不 rebuild 镜像。

**2. 容器内固定常量 / agent 自己想加的变量** — 在容器内向 `/state/env.local` 追加 `KEY=value` 行，下次 shell 启动即生效，重启保留，不需要改 compose、不需要 recreate 容器。值不做 shell 求值（`$VAR` / `$(cmd)` 原样保留），并拒绝覆盖 `PATH`、`HOME`、`SHELL`、`USER`、`UID`、`LOGNAME`、`PWD`、`OLDPWD` 这几个保留键以保护执行链。例如：

```sh
echo 'OPENAI_BASE_URL=https://my-proxy.example.com/v1' >> /state/env.local
echo 'AIDER_MODEL=claude-sonnet-4-6' >> /state/env.local
```

凭据穿透的边界遵循 `docs/security-model.md`：与 GitHub 直接交互的 PAT 不进 sandbox，而是只注入 `mcp-gateway`。

## 新增 sandbox 内 CLI 或工具

优先级：

1. 能在镜像构建时安装的工具，放进 `sandbox/Dockerfile`，路径落在只读镜像层。
2. 镜像 wrapper 自动下载的官方二进制（`claude` 这类），放 `/tool-bin/managed`，并提供镜像层 wrapper 调用；该子目录不在 `PATH`。
3. 容器内动态安装但希望持久化的工具（`npm i -g`、用户拖入静态二进制、`pipx`/`cargo install`/`mise` 装出来的命令），目标位置是 `/tool-bin/user/{bin,npm-global/bin}` —— **在** `PATH`，重启后下次 shell 即生效。`pipx` / `cargo` / `mise` 等工具的安装位置可以通过 `/state/shell/zshrc.local` 设置 `PIPX_BIN_DIR=/tool-bin/user/bin`、`CARGO_HOME=/tool-bin/user/cargo` 等指过去。
4. 工具的普通状态放 `/state`，缓存放 `/cache`。优先通过 XDG 环境变量接入；不规矩的常见 home 路径由 entrypoint 统一 symlink，不要继续新增零碎 mount。
5. 持久化 shell 自定义写在 `/state/shell/{zshrc,zshenv,bashrc,profile}.local`，由镜像生成的启动骨架末尾 source；不要直接修改 `~/.zshrc`，会被覆盖。

Claude 这类自身支持 hooks/commands/skills 的工具，要把“会影响未来执行的入口”集中放进 `/state/entrypoints/<tool>`，再通过兼容 symlink 暴露给工具原路径。新增类似目录时优先用 `AGENT_SANDBOX_ENTRYPOINT_LINKS`，例如：

```env
AGENT_SANDBOX_ENTRYPOINT_LINKS=".codex/skills=codex/skills .codex/commands=codex/commands"
```

这样新增工具入口通常只需要改配置并重建容器，不需要重新 build 镜像。

## 替换默认放行策略

如果你的场景需要"默认拒绝"，在 `proxy/squid.conf` 里：

- 加回 `acl allowed_*` 与 `http_access allow allowed_http`
- 把 `ssl_bump splice all` 改成 `ssl_bump splice allowed_sni; ssl_bump terminate all`
- 把 `http_access allow all` 改成 `http_access deny all`

并在 `config/proxy-rules/` 下重新维护一个 `allowlist.txt`，让 `proxy/entrypoint.sh` 也把它拷进容器。

## 扩展验证

`scripts/verify.sh` 是当前固定运行形态的可执行验证基线。行为变化时同步：

- 更新断言覆盖新行为
- 更新 `docs/verification.md` 的预期描述
- 保证脚本能从仓库根目录安全执行
- 明确 cleanup（用 trap 清理容器，不留残余）
