# 验证说明

## 范围

这个仓库的验证分成两层：

- 开发阶段可安全执行的轻量文件与 shell 检查
- 拉起 Docker 栈并验证当前固定运行形态的运行时检查

如果你当前在共享环境或已经有运行中的本地栈，不要直接无脑跑这些脚本。它们会启动和停止本地服务。

## 安全的本地检查

这些检查不会启动容器：

```bash
test -f docs/verification.md
bash -n scripts/verify-hybrid.sh
docker compose -p agent_sandbox -f deploy/compose/compose.yaml config
```

注意：`docker compose config` 会把宿主机环境变量展开到输出里。如果你已经导出了 `GITHUB_PERSONAL_ACCESS_TOKEN`，不要把这段输出贴到外部系统。

## 运行验证

1. 运行 `bin/agent-sandbox up`。
2. 在 sandbox 内访问 `https://registry.npmjs.org`，预期成功。
3. 在 sandbox 内访问 `http://mcp-gateway:8080/status`，预期成功。
4. 读取 `MCP_GITHUB_URL`，预期默认指向 `http://mcp-gateway:8080/servers/github/mcp`。

对应脚本：

- `scripts/verify-hybrid.sh`

## 验证脚本

- `scripts/verify-hybrid.sh`
