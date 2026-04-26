# 扩展指南

## 新增 MCP 服务

1. 把新的 `stdio` MCP server 预装进 `mcp-gateway` 镜像。
2. 在 `config/mcp-gateway/servers.json` 里新增一个 named server。
3. 约定它的访问路径为 `/servers/<name>/...`。
4. 在 `docs/security-model.md` 或服务专属文档里说明它的用途、凭据边界和信任边界。
5. 如果它需要新的环境变量或 secret，只注入 `mcp-gateway`，不要注入 `sandbox` 或普通 `proxy`。

MCP 服务应该尽量窄。相比继续平铺很多容器，把多个 `stdio` server 收口在 `mcp-gateway` 的 named server 配置里，更符合这个项目当前的默认路径。

## 新增运行模式

1. 新建 `config/profiles/<profile>.env`。
2. 设置 `orchestration/lib/profile.sh` 使用到的开关。
3. 明确这个模式是否应注入代理变量。
4. 明确这个模式里 `proxy` 和 `mcp-gateway` 的预期角色。
5. 在 `docs/profiles.md` 里记录这个模式。
6. 如果这个模式有值得反复验证的行为，就补一份验证脚本。

当前 profile 本质上还是配置叠加层。如果新模式需要更强的服务隔离，应该同时修改 Compose 和启动逻辑，而不是只改文档说明。

## 调整代理规则

需要修改的是：

- `config/proxy-rules/allowlist.txt`
- `config/proxy-rules/blocklist.txt`

改完后，重新运行相关验证脚本，确认：

- 允许的目标仍能访问
- 被拦截的目标仍然失败

尽量使用精确域名，不要一开始就放宽成大面积通配。allowlist 越小，越容易推导暴露面。

## 扩展验证

`scripts/` 下的现有脚本是各 profile 的可执行验证基线。行为变化时，应该同时做这几件事：

- 更新对应脚本
- 更新 `docs/verification.md`
- 确保脚本能从仓库根目录安全执行
- 明确写出 cleanup，避免操作者留下残余容器
