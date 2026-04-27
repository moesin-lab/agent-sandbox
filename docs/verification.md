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
8. `trap cleanup EXIT` 触发 `docker compose down`

任何一条失败脚本以非 0 退出。脚本写法假定从仓库根目录或 `scripts/` 目录调用都行，但务必在能启停容器的本地环境里执行。
