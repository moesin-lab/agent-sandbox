# 验证说明

## 范围

仓库的验证分两层：

- **本地静态检查**：不启动容器
- **端到端运行验证**：`scripts/verify.sh`，启停整个本地栈

如果你当前在共享环境或已经有运行中的本地栈，不要直接无脑跑这些脚本——它们会启动和停止本地服务。

## 本地静态检查

```bash
test -f docs/verification.md
bash -n scripts/verify.sh
docker compose config
bin/agent-sandbox doctor
```

`docker compose config` 会把宿主机环境变量展开到输出里。如果你已经导出了 `GITHUB_PERSONAL_ACCESS_TOKEN` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`，不要把这段输出贴到外部系统。

## 端到端运行验证

`scripts/verify.sh` 会做以下断言：

1. `docker compose up -d` 拉起整个栈
2. sandbox 内 `curl` 可执行（基础工具链）
3. **放行链路**：`curl https://registry.npmjs.org` 成功（HTTPS SNI splice）
4. **拦截链路**：`curl https://api.github.com` 失败（默认 blocklist 列入）
5. **MCP 直连**：`curl http://mcp-gateway:8080/status` 成功（端口 8080 不在 NAT 规则）
6. **环境变量**：`MCP_GITHUB_URL` 指向 `http://mcp-gateway:8080/servers/github/mcp`
7. **代理透明**：sandbox 内 `HTTP_PROXY` / `HTTPS_PROXY` 都不存在
8. **持久化边界**：`/home/node` 是 host bind mount（不是 tmpfs），根文件系统是只读挂载
9. **执行入口收口**：`PATH` 不包含扁平 `/tool-bin`、`~/.local/bin` 或 `/workspace/bin`；`/tool-bin/managed` 不在 `PATH`，但 `/tool-bin/user/bin` 与 `/tool-bin/user/npm-global/bin` **在** `PATH`（持久化扩展点）
10. **写路径**：`/state`、`/cache`、`/logs`、`/tool-bin` 可写
11. **非破坏 clean-home 默认**：`XDG_CACHE_HOME=/cache/xdg`、`XDG_DATA_HOME=/state/xdg/data`、`XDG_STATE_HOME=/state/xdg/state` 且 `NPM_CONFIG_CACHE=/cache/npm`；shell history 写到 `/state/shell/history/`；旧默认分流留下的 cache / IDE / nix symlink 不再指向旧默认目标；已有真实 home 目录不由 entrypoint 删除
12. **/state 扁平化**：`/state/entrypoints` 不再存在；`/state/dev-cache` 存在
13. **Home auto-track**：容器内 `mkdir ~/.opencode-verify-test/` 写文件，host 侧 `runtime/home/.opencode-verify-test/` 立即可见
14. **Restart 持久化**：写文件到 `~/.persist-test`，`docker compose restart sandbox` 后内容仍在
15. **Shell rc 防 hijack**：往 `~/.zshrc` 写 garbage，restart 后 entrypoint 用镜像版本覆盖，garbage 消失
16. **Ephemeral cache/list**：默认 `.cache`、`.claude/cache`、`.codex/cache`、`.codex/.tmp` 等 cache/tmp 路径是 tmpfs mount，不是 host 侧 broken symlink；显式往 `/state/home-ephemeral.local` 加一行 `.test-ephemeral-verify ...`，restart 后该路径变 symlink；同样的尝试映射 `.zshrc` 会被 entrypoint 拒绝
17. **nix-portable 入场**：`command -v nix-portable` 成功
18. **CLI 与 cwd / 调用方式无关**：`bin/agent-sandbox doctor` 在 `/tmp` 下、通过 PATH 调用、通过 symlink 调用都成功（doctor 检查的是 `$ROOT/...` 路径，过 = ROOT 解析对）
19. **cwd 映射透传**：在 `runtime/workspaces/verify-passthrough/sub` 执行 `agent-sandbox pwd` 输出 `/workspace/verify-passthrough/sub`（workspace 内：cwd 映射 + 容器内 exec）；`agent-sandbox shell` 复用同一套映射逻辑；在 `/tmp` 执行 `agent-sandbox pwd` 输出 `/workspace`（workspace 外：回退到 `/workspace` + stderr 提示）
20. **Healthcheck + autoheal**：`proxy` / `mcp-gateway` 的 `Health.Status` 都达到 `healthy`；autoheal sidecar 容器 `running` 且 `NetworkMode=none`
21. **`--self` overlay**：down 后用 `AGENT_SANDBOX_SELF_DIR=$ROOT bin/agent-sandbox up --self` 重启；从 `$ROOT` 跑 `agent-sandbox pwd` 输出 `/self`，从 `$ROOT/sandbox` 跑输出 `/self/sandbox`，从 `/tmp` 跑仍回退到 `/workspace`
22. `trap cleanup EXIT` 触发 `docker compose down`

任何一条失败脚本以非 0 退出。脚本写法假定从仓库根目录或 `scripts/` 目录调用都行，但务必在能启停容器的本地环境里执行。
