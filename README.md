# AnyCodex

**一个菜单栏应用,装完即得两件事:看清所有 AI 编码工具的剩余额度,把任意 LLM 接进 Codex CLI / Claude Code。**

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/jingchang0623-crypto/anycodex/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)
[![Notarized](https://img.shields.io/badge/signed-Developer%20ID%20%2B%20Notarized-16d3b4?style=flat-square)](https://github.com/jingchang0623-crypto/anycodex/releases/latest)

AnyCodex = [CodexBar](https://github.com/steipete/CodexBar)(额度监控)+ [opencodex](https://github.com/lidge-jun/opencodex)(万能 provider 代理),合并成一个 macOS 客户端。两个上游都是持续维护的成熟开源项目,AnyCodex 只做胶水层:把 opencodex 运行时打包进 .app,由应用托管其生命周期,菜单栏统一入口。

## 它解决什么问题

用 AI 编码的人普遍面临两个日常麻烦:

1. **额度焦虑** — Codex、Claude Code、Cursor、Copilot……每家的会话/周/月额度分散在各自的网页里,想知道"我还能不能跑一个长任务"要挨个去查。
2. **模型切换成本** — Codex CLI 只认 OpenAI,Claude Code 只认 Anthropic;想用 Gemini、Grok、DeepSeek、Ollama 或自建中转,要么换工具要么改配置。

AnyCodex 把两件事都收进菜单栏:

- **额度监控**(来自 CodexBar):63 个 provider 的用量、重置倒计时、余额、消费统计、状态告警。复用你已有的登录(OAuth / CLI 凭据 / 浏览器 cookie),不存密码。
- **Provider 代理**(来自 opencodex):应用启动时自动拉起内嵌的 opencodex 代理,菜单点 "Manage AI Providers…" 打开它的 Web 管理台 —— OAuth 登录、API key、模型同步、账号池,全部可视化配置。配好后 `codex` 和 `claude` 命令行照常用,底层模型随你换。

## 安装

### 直接下载(推荐)

从 [Releases](https://github.com/jingchang0623-crypto/anycodex/releases) 下载最新的 `AnyCodex-*-universal.zip`,解压后把 **AnyCodex.app** 拖进"应用程序"文件夹,双击运行。

- 已做 Developer ID 签名 + Apple 公证,Gatekeeper 不拦截
- 通用二进制,Apple Silicon 与 Intel 均可
- 要求 macOS 14+

首次使用:

1. 菜单栏出现图标后,打开 设置 → Providers,启用你在用的服务(Codex 读 `~/.codex` 登录、Claude 读 Claude Code 凭据,首次会请求一次钥匙串授权,选"始终允许")
2. 菜单里 "Manage AI Providers…" 打开代理管理台,按需接入其他模型

### 从源码构建

```bash
git clone https://github.com/jingchang0623-crypto/anycodex.git
cd anycodex

# 1. 下载并内嵌 opencodex 运行时(需要 npm;bun 可选,会自动打包)
./Scripts/vendor-opencodex.sh

# 2. 打包(adhoc 签名,本机自用)
./Scripts/package_app.sh debug
open AnyCodex.app
```

正式分发版需要 Apple Developer 证书:

```bash
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APP_TEAM_ID=TEAMID \
APP_STORE_CONNECT_API_KEY_FILE=~/path/AuthKey_XXXX.p8 \
APP_STORE_CONNECT_KEY_ID=XXXX \
APP_STORE_CONNECT_ISSUER_ID=xxxx-xxxx \
./Scripts/sign-and-notarize.sh
```

## 架构

```
AnyCodex.app
├── CodexBar 主体(Swift,菜单栏 UI + 63 个 provider 额度抓取)
├── OpenCodexProxyManager(胶水层:进程托管、健康巡检、崩溃重启、退出回收)
└── Contents/Resources/opencodex(内嵌运行时:bun + opencodex,启动时自动运行于 :10100)
```

设计原则:**能复用上游的绝不重写**。额度抓取、菜单 UI、设置体系全部来自 CodexBar;provider 接入、OAuth、模型管理全部来自 opencodex 自带的管理台。本仓库相对上游的增量只有约 500 行胶水代码(`Sources/CodexBar/OpenCodex*.swift` + 打包脚本),因此可以持续跟进两个上游的更新:

```bash
git fetch upstream          # upstream = steipete/CodexBar
git merge upstream/main
./Scripts/vendor-opencodex.sh   # 更新内嵌的 opencodex 到最新版
```

注意:本 fork 已停用 Sparkle 自动更新(上游的更新源会把应用替换回原版 CodexBar),升级请通过 Releases 或源码构建。

## 常见问题

**菜单里 Codex 显示 "temporarily unavailable"?**
CodexBar 的 Codex 额度需要 ChatGPT 订阅登录(`codex login`)。如果你的 `~/.codex` 只配了第三方中转的 API key,官方额度无从读取——中转额度可通过 设置 → Providers → sub2api 配置(要求 HTTPS 端点)。

**Claude 显示 "No available fetch strategy"?**
Claude Code 的凭据存在系统钥匙串,首次读取需要授权:菜单点"刷新",弹窗选"始终允许"。

**代理端口冲突?**
默认端口 10100。菜单里可 Stop/Start 代理;配置由 opencodex 管理(`~/.opencodex`)。

**Codex 桌面 App 的模型选择器里看不到自定义模型?**
桌面 App 必须以 ChatGPT 账号登录(`codex login`)才会向代理请求模型列表;若 `~/.codex/auth.json` 里只有 `OPENAI_API_KEY`(API-key 模式,某些第三方切换工具会这样写),App 只显示内置官方模型。登录后完全退出再打开 App 即可。

**某个 provider 明明能用某模型,但列表里没有?**
opencodex 以 provider 的 `/v1/models` 探测结果为准,配置里手工写的模型会被剪掉。用自定义模型注册(不受探测剪枝影响):

```bash
./Scripts/register-custom-models.sh <provider> gpt-5.6-sol gpt-5.5 gpt-5.4
./Scripts/register-custom-models.sh --list    # 查看已注册的
```

脚本可重复运行(已注册的自动跳过),注册后自动同步目录,重启 Codex App 生效。

## 致谢与许可

- [steipete/CodexBar](https://github.com/steipete/CodexBar) — Peter Steinberger 的菜单栏额度监控,本项目的主体(MIT);provider 相关的详细文档见上游 [docs/](https://github.com/steipete/CodexBar/tree/main/docs)
- [lidge-jun/opencodex](https://github.com/lidge-jun/opencodex) — 万能 provider 代理,本项目的内嵌运行时(MIT)

本项目基于 MIT 许可发布,保留上游版权声明,见 [LICENSE](LICENSE)。

---

*AnyCodex is a merged client of CodexBar (AI coding-provider usage monitoring, 63 providers) and opencodex (universal provider proxy for Codex CLI / Claude Code), shipped as one signed & notarized macOS menu bar app. Install once, watch every quota, route any model.*
