# 运行模式

## 概览

Profile 就是放在 `config/profiles/` 下的普通 env 文件。每个 profile 通过以下字段描述 sandbox 的预期运行方式：

- 是否注入代理环境变量
- 是否优先依赖 MCP 路径
- sandbox 的名义网络模式标签

可以这样选择 profile：

```bash
bin/agent-sandbox up <profile>
```

如果没有显式传入 profile，`bin/agent-sandbox` 会回退到 `config/defaults.env` 里的 `DEFAULT_PROFILE`。

## `mcp-only`

文件：`config/profiles/mcp-only.env`

行为：

- `ENABLE_PROXY=0`
- `SANDBOX_NETWORK_MODE=isolated`

当你希望 sandbox 避免通用外网访问，而把外部能力收口到 MCP 服务时，使用这个模式。

## `proxy-gated`

文件：`config/profiles/proxy-gated.env`

行为：

- `ENABLE_PROXY=1`
- `SANDBOX_NETWORK_MODE=proxy`

当你希望普通依赖源或文档站点可通过代理 allowlist 访问，同时日常工作主要依赖普通代理而不是 MCP 路径时，使用这个模式。

## `hybrid`

文件：`config/profiles/hybrid.env`

行为：

- `ENABLE_PROXY=1`
- `SANDBOX_NETWORK_MODE=proxy`

当你的日常开发既需要代理控制下的普通出网，又需要 `mcp-gateway` 承接高风险操作时，使用这个模式。

## 实际差异

| 模式 | sandbox 中是否注入代理 | 是否预期优先走 MCP gateway | 典型目标 |
| --- | --- | --- | --- |
| `mcp-only` | 否 | 是 | 强制外部操作走 MCP |
| `proxy-gated` | 是 | 否 | 只允许列表内出网 |
| `hybrid` | 是 | 是 | 同时利用代理便利性和 MCP 控制 |

这些 profile 文件表达的是运行意图和运行时环境。当前 compose 拓扑固定为 `sandbox + proxy + mcp-gateway`，profile 不会动态增删服务。
