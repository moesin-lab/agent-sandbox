# Agent Containment Starter Kit 设计文档

## 概述

这个仓库是一个面向 macOS + Docker Desktop 的起步项目，用来把编码 Agent 运行在受约束的沙盒里，同时尽量保留可用的开发体验。

它把三类能力整理为一个完整系统：

1. `sandbox` 模块：负责在 Docker 容器里运行 Agent，并提供有明确边界的默认运行环境。
2. `mcp` 模块：把敏感或高价值的外部能力收口到受控工具层，而不是让 Agent 直接走 shell 联网。
3. `proxy` 模块：提供另一条受规则约束的出网路径，用于依赖安装、文档访问等普通网络需求。

这个项目不是单纯的 Docker 沙盒模板，而是一个单仓库参考实现：`sandbox`、`mcp`、`proxy` 都是仓库内的一等模块，可以组合成标准运行模式，并通过统一入口进行管理。

## 目标

- 提供一套强 opinionated、基本开箱即用的 Agent 安全运行模板。
- 让 Agent 直连敏感远端目标的成本高于走受控路径的成本。
- 支持三种标准运行模式：`mcp-only`、`proxy-gated`、`hybrid`。
- 保留良好的扩展性，使新增 MCP 服务、代理规则和运行 profile 时不需要重构仓库。
- 把运行态数据收拢到仓库内部，而不是散落在宿主机各处。

## 非目标

- 第一版不支持 Windows、WSL 或通用 Linux 的跨平台兼容。
- 第一版不做完整的 GitHub 自动化产品。
- 第一版不做多实例并发编排平台。
- 第一版不做图形化面板或 Web UI。
- 第一版不同时支持多套代理实现。

## 问题背景

编码 Agent 很容易退回到它最熟悉的行为模式。只要给它通用 shell 权限，它往往就会优先选择直接写 `curl`、直接调 CLI，而不是遵守你为它准备的更安全的 MCP 接口。

这会带来几个直接问题：

- MCP 明明存在，但 Agent 可能绕开不用。
- 细粒度 Token 不能解决重试风暴和无节制调用。
- Prompt 约束不是可靠的执行边界。

因此，这个系统必须提供基础设施层面的约束：

- 默认情况下，Agent 不应该直接访问敏感远端目标。
- 敏感能力必须通过显式、受控的接口暴露出来。
- 同时又不能把正常开发工作彻底废掉。

## 设计原则

### 受控能力出口

危险或高价值的外部操作必须经过专门的、可审查的能力出口。这个设计默认把 shell 联网视为不可信路径。

### 强默认值

仓库应该在少量修改配置后即可运行，而不是让用户先自己设计目录结构和启动方式。

### 稳定模块边界

系统需要明确拆分以下职责：

- Agent 运行时容器
- 受控外部能力层
- 网络出网控制层
- 负责组合三者的编排层

### 通过配置扩展

Profile、规则、服务选择等变化点应尽量落在配置层，而不是散落在硬编码 shell 逻辑中。

### 仓库内运行态

宿主机上的挂载目录、日志、状态文件、持久化 home 数据等都应收拢到仓库管理的运行目录下，并默认加入 Git ignore。

## 仓库结构

仓库结构应按职责稳定性来划分，而不是堆积零散脚本：

```text
.
├── bin/
├── config/
├── docs/
├── mcp/
├── orchestration/
├── proxy/
├── runtime/
├── sandbox/
└── templates/
```

### `sandbox/`

负责 Agent 容器本身：

- Dockerfile
- entrypoint
- watchdog
- 启动 wrapper
- shell 初始化
- 挂载约定

它的职责很单一：提供一个稳定、受约束、可观察的 Agent 运行舱。

### `mcp/`

负责所有受控外部能力，并把服务作为可组合模块组织：

- `services/`：具体服务实现，例如 `github/`、`web/`
- `profiles/`：能力组合方案，例如不同场景下暴露给 Agent 的服务集合

这样新增一个工具面，应该只是增加服务模块并把它接入某个 profile，而不是回头改沙盒。

### `proxy/`

负责受控出网：

- 第一版只保留一种默认代理实现
- 使用 `rules/` 目录管理 allowlist 和 blocklist
- 提供验证代理规则是否生效的相关材料

代理逻辑独立于沙盒，未来无论替换规则还是替换代理实现，都不需要动 `sandbox/` 的核心结构。

### `orchestration/`

负责编排和生命周期：

- 服务组合描述
- 模式切换逻辑
- 健康检查
- 环境装配
- 供 `bin/` 入口调用的底层命令

它只做装配，不吞掉模块自身职责。

### `config/`

负责所有用户可调配置：

- 环境变量
- 路径默认值
- profile 定义
- MCP 服务与 profile 选择
- 代理规则选择
- workspace 映射

这是项目最主要的扩展层。

### `templates/`

负责示例集成材料：

- 示例 `.env`
- 示例 shell function
- 示例 override 配置

用户可以基于这些模板调整自己的接入方式，而不必直接改动核心源码。

### `runtime/`

负责宿主机侧运行态数据，并默认加入 Git ignore：

- `runtime/workspaces/`
- `runtime/home/`
- `runtime/logs/`
- `runtime/state/`

这让仓库变成一个自包含系统，不再依赖固定的宿主机路径，例如 `~/cc_mnt`。

### `docs/`

负责使用者和维护者文档：

- 快速开始
- 架构说明
- profile 说明
- 安全模型
- 扩展指南
- 验证指南
- 排障说明

## 标准运行模式

仓库应内置三种一等运行 profile。

### `mcp-only`

特征：

- Agent 容器不具备通用外网访问能力
- 敏感操作只能通过 MCP 服务完成
- 网页查询、GitHub 操作等都走受控能力层

适用场景：

- 对滥用风险最敏感、希望默认最稳妥的自动化 Agent 工作流

### `proxy-gated`

特征：

- Agent 容器通过仓库内代理访问外网
- allowlist 中的依赖源和文档站点可访问
- GitHub API 等敏感目标在出网层被拦截

适用场景：

- 需要频繁安装依赖、查文档，但仍不希望 Agent 直接碰受保护接口的开发任务

### `hybrid`

特征：

- 普通出网流量走代理 allowlist
- 敏感能力仍强制走 MCP
- 同时兼顾日常开发便利性和高风险能力的收口

适用场景：

- 交互式开发场景下的默认推荐模式

## 模式表示方式

运行模式不应写成脆弱的 shell 分支，而应该作为配置数据存在。

每个模式至少需要声明：

- 启用哪些服务
- 是否给 sandbox 注入代理环境变量
- 暴露哪个 MCP profile
- 使用哪套代理规则
- 应启用哪些健康检查
- 需要先启动哪些运行依赖

这样未来新增 `offline-strict`、`research-heavy` 之类模式时，主要是加配置，而不是重写逻辑。

## 宿主机运行目录布局

仓库应直接拥有宿主机侧挂载目录布局。

建议结构：

```text
runtime/
├── home/
├── logs/
├── state/
└── workspaces/
```

### `runtime/workspaces/`

用于放置允许给 Agent 操作的项目目录，或者这些目录的链接入口。它是原来 `~/cc_mnt` 习惯的仓库内替代品。

### `runtime/home/`

用于保存容器内用户态的持久化数据，例如 shell history、工具状态和缓存。

### `runtime/logs/`

用于保存 sandbox 生命周期脚本、watchdog、proxy、MCP 服务的日志。

### `runtime/state/`

用于保存 socket、lock、pid 和其他临时状态文件，要求可观察、可排障。

所有运行目录都应加入 Git ignore，只保留必要的占位文件维持结构。

## 宿主机入口整合

现有 `claude-sandbox()` shell function 说明了不错的使用体验，但它硬编码了太多个人环境假设：

- 固定挂载根
- 固定镜像名
- 固定容器名
- 固定 Dockerfile 位置
- 固定路径推导方式

新项目应该保留这种“命令即入口”的体验，但把真正逻辑收进仓库自带入口，例如 `bin/agent-sandbox`。

宿主机 shell function 只作为薄封装存在，调用仓库命令，而不是继续充当系统真实逻辑来源。

## 能力边界

### Sandbox 边界

`sandbox` 模块需要默认假设 Agent 会尝试任意 shell 操作。因此：

- 网络策略不能依赖 Prompt 遵守
- 敏感远端访问不能依赖 shell 自律
- 宿主机挂载路径必须显式、收窄

### MCP 边界

`mcp` 层是高价值能力的受控出口。第一版至少应包含：

- 面向 GitHub 之类受保护远端的服务骨架
- 面向网页搜索和抓取的服务骨架

第一版不要求能力完整，但必须把控制平面表达清楚。

### Proxy 边界

`proxy` 层是普通网络访问的受控通道，不是敏感能力执行通道。它的策略重点应放在：

- 放行依赖源和文档站点
- 拦截敏感或高滥用风险目标
- 让允许面和拦截面可见、可审查

## 安全模型

这个项目是一个 containment starter kit，不是对抗强攻击者的正式安全沙箱。

它主要解决的威胁模型是：

- Agent 误用 shell 联网
- 通过重试或临时脚本对外部 API 狂刷请求
- 工作流逐渐偏离受控 MCP 路径

第一版不完整解决的威胁包括：

- 恶意代码试图进行内核逃逸
- 多个互不信任租户之间的强隔离
- 高级供应链校验
- 超出挂载边界与环境变量边界之外的全面防泄露

文档中应明确写出这点，避免让使用者误以为它提供了形式化强安全保证。

## 第一版交付范围

第一版应交付一个完整闭环，而不是把所有可能性一次性做完。

### 第一版包含

- 一套可运行的 sandbox 镜像和启动链路
- 一套 watchdog 和 start-wrapper 机制
- 一种默认代理实现
- 一个 GitHub MCP 服务骨架
- 一个 Web MCP 服务骨架
- 一个统一操作入口
- 三种标准运行 profile
- 仓库内运行目录
- 验证脚本和说明文档

### 第一版明确不包含

- 多种代理引擎并存
- 多实例编排
- Windows / WSL 支持
- 完整 GitHub 自动化工作流
- 图形化管理界面

## 操作入口

仓库应暴露一个统一、清晰的控制面。

示例命令族：

- `bin/agent-sandbox up mcp-only`
- `bin/agent-sandbox up proxy-gated`
- `bin/agent-sandbox up hybrid`
- `bin/agent-sandbox shell`
- `bin/agent-sandbox logs`
- `bin/agent-sandbox doctor`
- `bin/agent-sandbox down`

这些命令应成为稳定用户接口，底层的 `orchestration/` 细节对使用者保持隐藏。

## 验证要求

这个项目要可信，边界就必须可验证。第一版至少要证明以下行为：

1. Sandbox 能启动，并进入预期 workspace。
2. 在 `mcp-only` 下，直连被拦目标会失败。
3. 在 `proxy-gated` 下，allowlist 目标可通，敏感目标失败。
4. 在 `hybrid` 下，普通出网与受控 MCP 能力可同时成立。
5. Watchdog、日志和状态目录按预期工作。

这些验证既要写进文档，也应尽可能落成可执行验证脚本。

## 文档规划

至少需要以下文档：

- `README.md`：五分钟启动
- `docs/architecture.md`
- `docs/profiles.md`
- `docs/security-model.md`
- `docs/extending.md`
- `docs/verification.md`

文档应同时面向两类读者：

- 想直接拿来用的操作者
- 想安全扩展它的维护者

## 扩展性规划

项目应至少保留三类扩展空间。

### 服务扩展

新增 MCP 服务时，应能直接加到 `mcp/services/` 下，而不需要重做 sandbox。

### 策略扩展

新增 allowlist、blocklist、runtime profile 时，应主要落在 `config/` 和 `proxy/rules/`，避免复制逻辑。

### 入口扩展

宿主机快捷命令可以变化，但它们都应该是对仓库统一入口的薄封装，而不是另起一套控制逻辑。

## 现有材料迁移原则

这个设计应吸收现有本地实现中已经验证过的部分：

- `~/.claude/docker-sandbox` 中的镜像与启动习惯
- 现有 watchdog 和 start-wrapper 的进程管理经验
- `~/.zsh/functions.zsh` 中已经验证过的使用体验
- 文章里总结出的防滥用与能力收口经验

但项目不应直接照搬个人路径假设，而应把这些经验归一化到仓库结构和配置边界里。

## 后续实现方向

下一阶段应把这份设计转换成明确的 implementation plan，至少覆盖：

- 精确文件布局
- 启动和 compose 编排策略
- profile 配置格式
- 默认代理实现选择
- MCP 服务骨架形态
- 验证脚本清单

实现计划必须严格围绕本文定义的第一版范围展开，避免失控扩张。
