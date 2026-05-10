# Bundle `mails` CLI into sandbox image

Date: 2026-05-10
Status: approved

## 背景与决策

最初诉求是「新增一个容器负责邮箱服务」，对接 [chekusu/mails](https://github.com/chekusu/mails)。但 mails 的服务端是 Cloudflare Worker：

- 入站邮件靠 Cloudflare Email Routing（CF 边缘独占）
- 出站默认链 `cloudflare → resend`，`env.EMAIL.send()` 是 CF Workers binding
- 状态存 D1（CF 托管 SQLite）

本地容器化只能跑 `wrangler dev`/`workerd`，且入站永远进不来，体验残缺。结论：mails 的设计意图就是 **client-only 容器化**，agent 通过 hosted `mails.dev` 或远端自建 Worker 走 HTTPS。所以不新增容器，把 `mails` CLI 装进现有 sandbox 镜像，跟 codex 同列。

## 改动

### 1. `sandbox/Dockerfile`

紧跟现有 `npm install -g @openai/codex` 之后增加：

```dockerfile
RUN NPM_CONFIG_PREFIX=/usr/local/share/npm-global npm install -g mails
```

- `NPM_CONFIG_PREFIX` 沿用 codex 的镜像 baked 路径，runtime 不会被 `/tool-bin/user/npm-global` 覆盖。
- 不 pin 版本（与 codex 一致）。
- PATH 已包含 `/usr/local/share/npm-global/bin`，无需调整。

### 2. proxy / 网络

不动。`config/proxy-rules/blocklist.txt` 是 default-allow，仅挡 `api.github.com` / `uploads.github.com`。`mails.dev` / `api.resend.com` / 用户自建 Worker 出站默认放行。

### 3. 持久化

不动。home 已是 bind mount → `runtime/home/`，`mails claim` 写入的 `~/.mails/config.json`（含 mailbox + `mk_...` API key）自动落 host 侧。

### 4. `scripts/verify.sh`

「Tooling sanity」段加一行存在性断言：

```bash
"${COMPOSE[@]}" exec -T sandbox sh -c 'command -v mails' >/dev/null
```

只验证安装成功。不验证功能（`claim` 需要人工批准 + 网络往返，不适合 CI）。

### 5. 文档

- `docs/extending.md` 第二节（"扩展 CLI 与工具"）列表脚注一句「`mails` 已镜像自带，沿用 npm-global baked path」。
- `docs/persistence.md` 高风险入口表加一行 `~/.mails/config.json`（mailbox API key）。

## 不做的事（YAGNI）

- 不 pin `MAILS_VERSION` ARG。
- 不内置 mails skill 文件到默认 `~/.claude/skills/`。
- 不为 mails 写 managed wrapper（mails 是普通 npm 包，无校验下载需求）。
- 不在 compose 暴露 mails 相关 env vars。
- 不动 verify.sh 之外的功能性测试（claim/send/code 都要外部凭据 + 网络往返）。

## 验证

- 镜像构建过：`bin/agent-sandbox build` 不挂在新增 RUN 上。
- `verify.sh` 通过：新增的 `command -v mails` 断言成功。
- 进入 sandbox 后 `mails version` 输出版本号；`mails claim` 在无浏览器环境进入 device-code 流程（mails CLI 已内建，不需要我们处理）。

## 风险

- mails 是较新的 npm 包，npm registry 偶发抓不到时 `npm install` 会失败 — `verify.sh` 的 `command -v mails` 会立刻暴露。
- credentials 写在 host 侧 `runtime/home/.mails/`，host 用户可见。这与现有 `~/.claude.json` / `~/.codex/` 同级，不引入新攻击面。

## 影响范围

| 文件 | 变更 |
| --- | --- |
| `sandbox/Dockerfile` | +1 RUN |
| `scripts/verify.sh` | +1 断言行 |
| `docs/extending.md` | +1 段 |
| `docs/persistence.md` | +1 表行 |
