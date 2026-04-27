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

需要把宿主机已有的环境变量（如 Agent CLI 的 API key）穿透进 sandbox 时，在 `compose.yaml` 的 `sandbox.environment` 列表里追加变量名（不带 `=`）即可：Docker compose 会从 host shell 读取并透传，未设置的不会出现在容器里。需要给容器内固定常量则用 `KEY=value` 形式。

凭据穿透的边界遵循 `docs/security-model.md`：高权限的 GitHub PAT（`GITHUB_PERSONAL_ACCESS_TOKEN`）不进 sandbox，而是只注入 `mcp-gateway`；sandbox 内的 git CLI 用单独的 `GITHUB_TOKEN`（推荐 fine-grained、scope 限到具体仓库）。

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
