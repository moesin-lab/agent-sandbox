# 安全模型

## 目标

这个仓库的设计目标是让“最安全的路径”同时也是“最顺手的路径”：

- 敏感能力应优先通过 MCP 服务暴露
- 常规出网流量应受到仓库自带代理规则约束
- 运行态数据应尽量留在仓库内管理的目录里

## 信任边界

### Host

宿主机负责运行 Docker，并通过 `bin/agent-sandbox` 拉起整套服务。它被视为可信边界，持有源码、本地凭据和仓库管理的运行目录。

### Sandbox Container

sandbox 是 Agent 运行的地方。它的信任级别应低于宿主机，所以它的可写范围被刻意收敛到挂载进来的 runtime 目录和 workspace。

### MCP Services

MCP sidecar 是敏感操作的受控接口。审计、凭据收口、请求校验、限流和 allow/deny 逻辑，都应该优先加在这里。

### Proxy

proxy 是通用出网的受控接口。它负责执行 `config/proxy-rules/` 里的 allowlist 和 blocklist。

## 当前约束模型

当前实现只覆盖了目标模型的一部分：

- 启用代理的 profile 会注入 `HTTP_PROXY` 和 `HTTPS_PROXY`
- proxy 规则会在启动时被复制进 Squid 容器
- runtime 数据统一从仓库管理目录挂载
- MCP profile 定义在使用前会先做校验

这个 starter kit 还不能宣称自己对所有绕过手法都具备完整隔离能力。尤其是当前 profile 选择对环境变量和操作流程的影响大于对 Compose 拓扑本身的重写。

## 主要针对的风险

- sandbox 意外直连敏感 API
- Agent 运行时里未经审视的工具蔓延
- 运行态数据散落到随意的宿主机路径
- 本该收口成受控能力时，Agent 仍然走“直接 `curl`”这类过宽路径

## 建议的使用习惯

- 尽量用满足任务要求的最窄 profile
- 新的敏感集成优先做成 MCP 服务
- proxy allowlist 尽量保持短小且明确
- 把验证脚本视为会修改环境的操作，因为它们会启动和停止容器
