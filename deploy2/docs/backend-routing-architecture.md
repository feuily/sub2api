# Backend HTTP 路由注册与模块功能分析

> 范围：Sub2API backend 主服务的启动过程、Gin 路由组装、访问控制边界、协议网关，以及 HTTP 路由映射的业务模块。
> 依据：当前仓库 `backend/cmd/server`、`backend/internal/server`、`backend/internal/server/routes` 和 `backend/internal/handler` 的实现。
> 本文是架构导读，不是稳定 API 契约；精确请求字段、响应结构和单个 endpoint 行为，应以对应 handler、service 和 API 测试为准。

## 1. 总体结论

Backend 的 HTTP 层采用分层注册模式。启动入口和应用组装分别见 [`main.go:55`](../../backend/cmd/server/main.go#L55) 与 [`wire.go:34`](../../backend/cmd/server/wire.go#L34)：

1. `cmd/server` 判定启动模式，并在常规模式下构建应用依赖。
2. Wire 将配置、repository、service、middleware、handler 和 server 依赖组装到一起。
3. `server.ProvideRouter` 创建 Gin 引擎并设置代理信任及 panic recovery。
4. `server.SetupRouter` 安装跨全站中间件，再调用内部路由分发器。
5. `server/routes` 以功能域注册系统 API、用户面板 API、管理员 API、支付 API 和多协议模型网关；页面资源路由由 `handler.RegisterPageRoutes` 注册。

路由不是单纯的 URL 到函数映射。它同时承担认证方式分流、限流、审计、运行模式隔离、模型准入、协议兼容、合成分组路由和运维记录等横切职责。尤其是模型网关，路径前缀只代表客户端协议入口之一；实际 handler 和上游协议还可能由 API Key 所属分组的平台、模型 allowlist 和 composite route 共同决定。

## 2. 启动与路由装配生命周期

### 2.1 主进程启动模式

[`main.go:55`](../../backend/cmd/server/main.go#L55) 在进入 HTTP 服务前先处理版本和初始化分支：

- `--version`：打印版本和构建信息后退出，不创建 HTTP 路由（[`main.go:60`](../../backend/cmd/server/main.go#L60)、[`main.go:64`](../../backend/cmd/server/main.go#L64)）。
- `--setup`：运行 CLI 设置流程（[`main.go:70`](../../backend/cmd/server/main.go#L70)）。
- 首次启动需要初始化且开启 auto-setup：执行环境配置初始化后继续常规启动（[`main.go:78`](../../backend/cmd/server/main.go#L78)）。
- 首次启动需要初始化且未开启 auto-setup：启动独立 Setup HTTP 服务（[`main.go:88`](../../backend/cmd/server/main.go#L88)）。

因此，启动行为共有 **4 条主要路径**：版本输出退出、CLI Setup、Setup HTTP 服务、常规 HTTP 服务；自动设置是常规 HTTP 服务路径上的预启动初始化分支，不单独创建 router。Setup HTTP router 由 `runSetupServer` 创建，并注册 `setup.RegisterRoutes`（[`main.go:97`](../../backend/cmd/server/main.go#L97)、[`main.go:98`](../../backend/cmd/server/main.go#L98)、[`main.go:105`](../../backend/cmd/server/main.go#L105)）。常规服务从 [`main.go:134`](../../backend/cmd/server/main.go#L134) 的 `runMainServer` 开始。

常规启动通过 Wire 的 `initializeApplication` 创建应用（[`wire.go:34`](../../backend/cmd/server/wire.go#L34)、[`wire.go:48`](../../backend/cmd/server/wire.go#L48)）。最终由 [`http.go:113`](../../backend/internal/server/http.go#L113) 的 `ProvideHTTPServer` 持有 Gin handler 和监听参数；主进程启动 `ListenAndServe`，并在收到 SIGINT/SIGTERM 时执行限时优雅关闭（[`main.go:173`](../../backend/cmd/server/main.go#L173)、[`main.go:190`](../../backend/cmd/server/main.go#L190)）。

### 2.2 从应用到 Gin Engine

常规路由入口可概括为：

```text
cmd/server.main
  └─ runMainServer
      └─ initializeApplication (Wire)
          └─ server.ProvideRouter
              ├─ gin.New
              ├─ Recovery
              ├─ configureTrustedProxies
              └─ SetupRouter
                  ├─ 全局请求中间件
                  ├─ 可选的内嵌前端与设置注入
                  └─ registerRoutes
                      ├─ common routes
                      ├─ /api/v1 面板 API
                      ├─ 根路径协议网关 / 兼容别名
                      └─ /api/v1/pages 页面内容 API
```

[`ProvideRouter`](../../backend/internal/server/http.go#L30) 使用 `gin.New` 并显式注册 Recovery（[`http.go:50`](../../backend/internal/server/http.go#L50)、[`http.go:51`](../../backend/internal/server/http.go#L51)）。release 模式会设置 Gin release mode（[`http.go:47`](../../backend/internal/server/http.go#L47)）。代理可信范围由 `server.trusted_proxies` 决定；未显式配置时禁用转发头信任（[`http.go:93`](../../backend/internal/server/http.go#L93)）。

### 2.3 全局中间件与路由注册顺序

[`SetupRouter`](../../backend/internal/server/router.go#L23) 在注册路由前按如下顺序安装全局中间件（注册代码见 [`router.go:59`](../../backend/internal/server/router.go#L59) 至 [`router.go:71`](../../backend/internal/server/router.go#L71)）：

1. 请求访问日志记录器。
2. Session Binding Context：统一采集请求关联的客户端 IP 和 User-Agent 信息。
3. 应用日志中间件。
4. CORS。
5. 安全响应头与 CSP；`frame-src` 来源通过设置服务的原子缓存动态提供。
6. Server Timing（由配置控制）。
7. 内嵌前端服务中间件（仅在嵌入前端可用时）；它同时支持设置注入和 HTML 缓存失效回调。
8. 各业务路由注册器。

`ProvideRouter` 在 `SetupRouter` 前安装 Recovery 与可信代理设置，因此 Panic Recovery 是更外层的保护（[`http.go:50`](../../backend/internal/server/http.go#L50) 至 [`http.go:52`](../../backend/internal/server/http.go#L52)）。设置更新后，可触发内嵌前端缓存失效和 CSP frame-src 刷新（[`router.go:42`](../../backend/internal/server/router.go#L42) 至 [`router.go:55`](../../backend/internal/server/router.go#L55)、[`router.go:79`](../../backend/internal/server/router.go#L79) 至 [`router.go:89`](../../backend/internal/server/router.go#L89)）。

## 3. 路由树与功能域

下列路径均以 HTTP method 与 path template 描述；`:id`、`:model` 等是 Gin 路径参数，`*subpath` 是 catch-all 子路径。

### 3.1 基础与运行状态路由

| 前缀 / 路径                       | 用途                                                          | 认证                                                                      |
| --------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `GET /health`                   | 轻量健康探测，返回服务状态                                    | 无；[`common.go:10`](../../backend/internal/server/routes/common.go#L10) |
| `GET /setup/status`             | 常规运行模式下告知前端 Setup 已完成                           | 无；[`common.go:23`](../../backend/internal/server/routes/common.go#L23) |
| `POST /api/event_logging/batch` | 兼容 Claude Code 遥测入口；不持久化业务数据，直接返回成功状态 | 无；[`common.go:17`](../../backend/internal/server/routes/common.go#L17) |

安装向导拥有自己的路由注册过程，仅在 Setup 服务运行时使用，不能与上表常规模式的 `/setup/status` 混淆（Setup router 初始化见 [`main.go:97`](../../backend/cmd/server/main.go#L97)，正常路由总装配见 [`router.go:99`](../../backend/internal/server/router.go#L99)）。

### 3.2 `/api/v1` 面板 API

[`registerRoutes`](../../backend/internal/server/router.go#L99) 创建 `/api/v1` 根组，并将它交给多个相互独立的注册函数（[`router.go:120`](../../backend/internal/server/router.go#L120) 至 [`router.go:134`](../../backend/internal/server/router.go#L134)）。典型的用户和管理员操作属于面板 API；它与使用 API Key 的推理网关是不同的认证域。

| 路由域                                                     | 代表性路径                                                                                                            | 模块职责 / 源码入口                                                                                                                                 |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/api/v1/auth`                                           | 注册、登录、2FA/passkey 登录、验证码、refresh/logout、密码找回、邀请码/优惠码校验、OAuth start/callback/绑定/注册完成 | 用户身份认证及身份提供方对接；[`routes/auth.go:16`](../../backend/internal/server/routes/auth.go#L16)                                              |
| `/api/v1/settings`                                       | `/public`、`/email-unsubscribe`                                                                                   | 面向匿名用户的公开设置和邮件退订；按客户端 IP 限流；[`routes/auth.go:243`](../../backend/internal/server/routes/auth.go#L243)                      |
| `/api/v1/model-plaza`                                    | 模型广场查询                                                                                                          | 可选 JWT；匿名访问、功能开关及 require_auth 由 handler 判定；[`routes/model_plaza.go:16`](../../backend/internal/server/routes/model_plaza.go#L16) |
| `/api/v1/user`                                           | profile、密码、资料、affiliate、账号身份绑定、通知邮箱、平台额度                                                      | 当前用户资料与账户安全管理；[`routes/user.go:12`](../../backend/internal/server/routes/user.go#L12)                                                |
| `/api/v1/user/totp`、`/passkeys`                       | 2FA 状态/setup/enable/disable/step-up；Passkey 注册、列表和维护                                                       | TOTP 与 WebAuthn Passkey 生命周期；[`routes/user.go:47`](../../backend/internal/server/routes/user.go#L47)                                         |
| `/api/v1/keys`                                           | 用户 API Key 的列表、读取、创建、更新、删除                                                                           | 用户调用凭证生命周期；[`routes/user.go:78`](../../backend/internal/server/routes/user.go#L78)                                                      |
| `/api/v1/groups`、`/api/v1/channels`                   | 可用分组、倍率、可用渠道                                                                                              | 用户侧资源发现；[`routes/user.go:95`](../../backend/internal/server/routes/user.go#L95)                                                            |
| `/api/v1/usage`                                          | 使用明细、错误、统计和 dashboard 聚合查询                                                                             | 用户账单可见性及调用可观测性；[`routes/user.go:102`](../../backend/internal/server/routes/user.go#L102)                                            |
| `/api/v1/announcements`、`/redeem`、`/subscriptions` | 公告/已读、卡密兑换、订阅与用量进度                                                                                   | 用户公告、权益兑换和订阅视图；[`routes/user.go:120`](../../backend/internal/server/routes/user.go#L120)                                            |
| `/api/v1/channel-monitors`、`/channel-monitor-v2`      | 监控状态及 V2 dimensions/snapshot/models/matrix/errors/users                                                          | 用户可见监控；V2 受功能开关和运行模式保护；[`routes/user.go:141`](../../backend/internal/server/routes/user.go#L141)                               |
| `/api/v1/payment`                                        | 配置、checkout、plans、limits、订单、取消、退款申请                                                                   | 登录用户支付和订单流程；[`routes/payment.go:27`](../../backend/internal/server/routes/payment.go#L27)                                              |
| `/api/v1/payment/public`                                 | 订单结果验证、resume token 解析                                                                                       | 匿名支付结果恢复；订单验证接口按 IP 限流；[`routes/payment.go:71`](../../backend/internal/server/routes/payment.go#L71)                            |
| `/api/v1/payment/webhook`                                | EasyPay、Alipay、WeChat Pay、Stripe、Airwallex 通知                                                                   | 支付平台回调，不使用用户 JWT；[`routes/payment.go:79`](../../backend/internal/server/routes/payment.go#L79)                                        |
| `/api/v1/admin/payment`                                  | 管理看板、配置、订单处理、plans、provider 管理                                                                        | 管理员支付运营；[`routes/payment.go:92`](../../backend/internal/server/routes/payment.go#L92)                                                      |
| `/api/v1/admin/**`                                       | 见下方管理员模块清单                                                                                                  | 后台运营与系统管理；[`routes/admin.go:14`](../../backend/internal/server/routes/admin.go#L14)                                                      |
| `/api/v1/plugin-ui/:token/*path`                         | 插件 UI 静态资源                                                                                                      | 短期能力 URL，不属于常规管理员 JWT 业务路由；[`routes/admin.go:23`](../../backend/internal/server/routes/admin.go#L23)                             |
| `/api/v1/pages/:slug`、图片及管理员列表                  | 页面内容、页面图片、管理页面列表                                                                                      | 三种不同授权处理；[`page_handler.go:261`](../../backend/internal/handler/page_handler.go#L261)                                                     |

认证路由中共有 **6 个 OAuth provider**：LinuxDo、GitHub、Google、WeChat、OIDC、DingTalk；对应 start、callback、pending registration、bind-login、create-account 等阶段（[`auth.go:75`](../../backend/internal/server/routes/auth.go#L75) 至 [`auth.go:239`](../../backend/internal/server/routes/auth.go#L239)）。并非所有阶段都要求已登录会话。新增 provider 时，应明确区分“登录/注册”和“绑定当前账户”的 intent 与状态校验。

### 3.3 管理员功能模块

管理员 API 由 [`RegisterAdminRoutes`](../../backend/internal/server/routes/admin.go#L14) 聚合注册。除少数独立的能力 URL 外，模块位于 `/api/v1/admin`，当前由 **34 个功能注册调用**构成（[`admin.go:37`](../../backend/internal/server/routes/admin.go#L37) 至 [`admin.go:134`](../../backend/internal/server/routes/admin.go#L134)）；这是注册函数调用数，不等同于 endpoint 数或下表合并后的资源域数。

| 管理域                         | 典型路径前缀                                                                                              | 主要职责 / 注册函数                                                                                                                                                                                                                                                                                                                        |
| ------------------------------ | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 合规确认、Dashboard            | `/compliance`、`/dashboard`                                                                           | 部署合规、总览/趋势/聚合指标；[`admin.go:164`](../../backend/internal/server/routes/admin.go#L164)、[`admin.go:283`](../../backend/internal/server/routes/admin.go#L283)                                                                                                                                                                 |
| 用户与用户属性                 | `/users`、`/user-attributes`                                                                          | 用户生命周期、余额/限制/配额和扩展属性；[`admin.go:302`](../../backend/internal/server/routes/admin.go#L302)、[`admin.go:720`](../../backend/internal/server/routes/admin.go#L720)                                                                                                                                                       |
| 分组与账号池                   | `/groups`、`/accounts`                                                                                | 平台分组、容量/倍率/allowlist/composite routes；上游账号和凭证运维；[`admin.go:329`](../../backend/internal/server/routes/admin.go#L329)、[`admin.go:360`](../../backend/internal/server/routes/admin.go#L360)                                                                                                                           |
| 供应商 OAuth 与 CN provider    | `/openai`、`/gemini`、`/antigravity`、`/grok`、`/cn-providers`                                  | 凭证交换、刷新、额度/余额及供应商能力；[`admin.go:456`](../../backend/internal/server/routes/admin.go#L456) 至 [`admin.go:511`](../../backend/internal/server/routes/admin.go#L511)                                                                                                                                                      |
| 代理、渠道、管理 API Key       | `/proxies`、`/channels`、`/api-keys`                                                                | 网络代理和质量检查、渠道/定价、Key 策略；[`admin.go:186`](../../backend/internal/server/routes/admin.go#L186)、[`admin.go:521`](../../backend/internal/server/routes/admin.go#L521)、[`admin.go:783`](../../backend/internal/server/routes/admin.go#L783)                                                                               |
| 订阅、卡密与优惠码             | `/subscriptions`、`/redeem-codes`、`/promo-codes`                                                   | 订阅履约、兑换码和促销码管理；[`admin.go:542`](../../backend/internal/server/routes/admin.go#L542)、[`admin.go:558`](../../backend/internal/server/routes/admin.go#L558)、[`admin.go:684`](../../backend/internal/server/routes/admin.go#L684)                                                                                          |
| 公告与系统设置                 | `/announcements`、`/settings`                                                                         | 公告 CRUD、系统参数/邮件模板/安全策略及 Scoped Admin Key；[`admin.go:444`](../../backend/internal/server/routes/admin.go#L444)、[`admin.go:570`](../../backend/internal/server/routes/admin.go#L570)                                                                                                                                     |
| 数据管理与备份                 | `/data-management`、`/backups`                                                                        | 外部数据源、S3、备份作业/策略、下载及恢复；[`admin.go:616`](../../backend/internal/server/routes/admin.go#L616)、[`admin.go:640`](../../backend/internal/server/routes/admin.go#L640)                                                                                                                                                    |
| 运维与系统操作                 | `/ops`、`/system`                                                                                     | 请求/上游错误、告警、日志、实时信号、更新/回滚/重启；[`admin.go:193`](../../backend/internal/server/routes/admin.go#L193)、[`admin.go:672`](../../backend/internal/server/routes/admin.go#L672)                                                                                                                                          |
| 定时测试与监控                 | `/scheduled-test-plans`、`/channel-monitors`、`/channel-monitor-templates`、`/channel-monitor-v2` | 计划测试、监控规则/模板/历史与 V2 分析；[`admin.go:732`](../../backend/internal/server/routes/admin.go#L732)、[`admin.go:796`](../../backend/internal/server/routes/admin.go#L796)、[`admin.go:845`](../../backend/internal/server/routes/admin.go#L845)                                                                                |
| 风控、提示词审计、操作审计     | `/risk-control`、`/prompt-audit`、`/audit-logs`                                                     | 内容审核、策略/事件查询清理和管理员操作审计；[`admin.go:138`](../../backend/internal/server/routes/admin.go#L138)、[`admin.go:154`](../../backend/internal/server/routes/admin.go#L154)、[`admin.go:172`](../../backend/internal/server/routes/admin.go#L172)                                                                           |
| 插件、TLS 指纹、错误透传、返利 | `/plugins`、`/tls-fingerprint-profiles`、`/error-passthrough-rules`、`/affiliates`                | 插件生命周期、TLS 模板、错误规则和邀请返利运营；[`admin.go:744`](../../backend/internal/server/routes/admin.go#L744)、[`admin.go:755`](../../backend/internal/server/routes/admin.go#L755)、[`admin.go:766`](../../backend/internal/server/routes/admin.go#L766)、[`admin.go:825`](../../backend/internal/server/routes/admin.go#L825) |

Scoped Admin Key 是受限管理员访问能力，生命周期端点位于 `/api/v1/admin/settings/admin-api-keys`（[`custom_admin_keys.go:10`](../../backend/internal/server/routes/custom_admin_keys.go#L10)）。对账号范围和分组模型范围的限制分别由账号与分组路由层中间件执行（[`admin.go:34`](../../backend/internal/server/routes/admin.go#L34)、[`admin.go:331`](../../backend/internal/server/routes/admin.go#L331)）；维护这些路由时应保留其资源级授权逻辑，不能只依赖“请求已通过管理员认证”。

### 3.4 模型与媒体网关

网关由 [`RegisterGatewayRoutes`](../../backend/internal/server/routes/gateway.go#L22) 直接注册在 Gin Engine 根部，而非 `/api/v1`（总装配见 [`router.go:131`](../../backend/internal/server/router.go#L131)）。因此 API Key 客户端调用的 `/v1` 和 `/v1beta` 不会经过面板 JWT 认证组。主要协议入口如下：

| 协议入口                  | 路径示例                                                                                                  | 业务能力                                                                                                                                                                                                                                      |
| ------------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Anthropic / Claude 兼容   | `/v1/messages`、`/v1/messages/count_tokens`、`/v1/models`、`/v1/usage`                            | 对话、token 计数、模型发现和 Key 用量；部分请求按分组平台分发至 OpenAI-compatible handler；[`gateway.go:180`](../../backend/internal/server/routes/gateway.go#L180)                                                                          |
| OpenAI 兼容               | `/v1/responses`、`/v1/chat/completions`、`/v1/embeddings`、`/v1/images/*`                         | Responses、Chat Completions、向量和图像能力，受平台能力约束；[`gateway.go:180`](../../backend/internal/server/routes/gateway.go#L180)                                                                                                        |
| OpenAI/Codex 直接兼容别名 | `/responses`、`/chat/completions`、`/models`、`/backend-api/codex/*`                              | 为不带 `/v1` 的客户端和 Codex 客户端提供兼容路径；仍使用 API Key 认证和相应准入中间件；[`gateway.go:370`](../../backend/internal/server/routes/gateway.go#L370)、[`gateway.go:387`](../../backend/internal/server/routes/gateway.go#L387) |
| Gemini 原生               | `/v1beta/models/*`、`/v1beta/cachedContents`                                                          | Gemini 模型调用、模型发现和由网关管理的上下文缓存；[`gateway.go:338`](../../backend/internal/server/routes/gateway.go#L338)                                                                                                                  |
| Antigravity 固定平台      | `/antigravity/v1/*`、`/antigravity/v1beta/*`、`/antigravity/models`                                 | 显式锁定 Antigravity 平台的 Claude/Gemini 兼容入口；[`gateway.go:491`](../../backend/internal/server/routes/gateway.go#L491)、[`gateway.go:494`](../../backend/internal/server/routes/gateway.go#L494)                                      |
| 异步图像/批处理           | `/v1/images/generations/async`、`/v1/images/tasks/:task_id`、`/v1/images/batches/*`                 | 异步任务提交、轮询、批次、结果下载及清理；[`gateway.go:260`](../../backend/internal/server/routes/gateway.go#L260)                                                                                                                           |
| 视频任务                  | `/v1/videos*`                                                                                           | 视频生成、编辑、扩展、状态和内容读取；平台能力在 handler dispatch 中约束；[`gateway.go:92`](../../backend/internal/server/routes/gateway.go#L92)                                                                                             |
| Grok 媒体与搜索           | `/v1/tts`、`/v1/stt`、`/v1/custom-voices/*`、`/v1/realtime`、`/v1/web_search`、`/v1/x_search` | 语音、实时、搜索和媒体 API；限定到相应的平台能力；[`gateway.go:465`](../../backend/internal/server/routes/gateway.go#L465)、[`gateway.go:473`](../../backend/internal/server/routes/gateway.go#L473)                                        |
| Seedance 任务             | `/api/v3/contents/generations/tasks`，以及 `/v3`、`/v1` 和根路径别名                                | 异步视频/内容任务的多个客户端兼容前缀；[`gateway.go:373`](../../backend/internal/server/routes/gateway.go#L373)                                                                                                                              |

网关对同一业务能力维护多个协议路径和别名是有意设计。调用是否可用由 API Key 认证（[`api_key_auth.go:54`](../../backend/internal/server/middleware/api_key_auth.go#L54)）、Key 状态/用户状态、分组配置、订阅或计费状态、平台适配、模型 allowlist 及具体端点能力共同决定，而不能仅从 URL 是否存在推断。

## 4. 认证、授权与中间件边界

### 4.1 三类主要认证上下文及凭证变体

| 认证类型     | 典型范围                                 | 识别内容                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------ | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 用户 JWT     | `/api/v1/auth` 登录后的用户面板接口    | 验证 Bearer token、token version、用户状态，并加载最新用户；[`jwt_auth.go:40`](../../backend/internal/server/middleware/jwt_auth.go#L40)                                                                                                                                                                                                                                                                                                                                                         |
| 管理员身份   | `/api/v1/admin/**`、管理员页面         | 3 种凭证机制：管理员 JWT、Admin API Key、Scoped Admin Key；WebSocket 另有 subprotocol 传递 JWT 的传输适配；[`admin_auth.go:27`](../../backend/internal/server/middleware/admin_auth.go#L27)、[`admin_auth.go:36`](../../backend/internal/server/middleware/admin_auth.go#L36)、[`admin_auth.go:50`](../../backend/internal/server/middleware/admin_auth.go#L50)、[`admin_auth.go:240`](../../backend/internal/server/middleware/admin_auth.go#L240)                                           |
| 用户 API Key | 模型网关 `/v1`、`/v1beta` 和兼容别名 | 3 种凭证传递位置：`Authorization: Bearer`、`x-api-key`、`x-goog-api-key`；Gemini 入口另使用 Google 兼容认证适配器；[`api_key_auth.go:58`](../../backend/internal/server/middleware/api_key_auth.go#L58)、[`api_key_auth.go:72`](../../backend/internal/server/middleware/api_key_auth.go#L72)、[`api_key_auth.go:83`](../../backend/internal/server/middleware/api_key_auth.go#L83)、[`api_key_auth_google.go:25`](../../backend/internal/server/middleware/api_key_auth_google.go#L25) |

不能把三者混为一谈：管理员 UI 并非通过模型 API Key 授权；模型请求也不应被误接到面板 JWT 中间件。

### 4.2 面板请求的保护链

- `/api/v1/auth` 登录/注册类入口使用 Backend Mode Auth Guard、审计及端点级 Redis 限流（[`auth.go:29`](../../backend/internal/server/routes/auth.go#L29)、[`auth.go:35`](../../backend/internal/server/routes/auth.go#L35)）。高风险认证限流在 Redis 故障时按配置 fail-close。
- 已登录用户组在用户路由注册器中统一挂 JWT、Backend Mode User Guard、全局面板限流与审计（[`user.go:21`](../../backend/internal/server/routes/user.go#L21) 至 [`user.go:26`](../../backend/internal/server/routes/user.go#L26)）。较重的 usage/dashboard 及 V2 监控查询另外挂重请求限流（[`user.go:99`](../../backend/internal/server/routes/user.go#L99)、[`user.go:146`](../../backend/internal/server/routes/user.go#L146)）。
- 管理员组统一挂 Admin Auth、面板限流、审计和 Admin Compliance Guard（[`admin.go:26`](../../backend/internal/server/routes/admin.go#L26) 至 [`admin.go:34`](../../backend/internal/server/routes/admin.go#L34)）。
- 特定敏感操作再追加 Step-up Authentication，例如 Scoped Admin Key 管理、导出上游凭证、修改备份/S3 目标、创建/下载/恢复备份及插件管理等（[`custom_admin_keys.go:13`](../../backend/internal/server/routes/custom_admin_keys.go#L13)、[`admin.go:419`](../../backend/internal/server/routes/admin.go#L419)、[`admin.go:630`](../../backend/internal/server/routes/admin.go#L630)、[`admin.go:660`](../../backend/internal/server/routes/admin.go#L660)、[`admin.go:771`](../../backend/internal/server/routes/admin.go#L771)）。
- 公开设置、公开模型广场、公开支付验证等端点不等于“无限制”：它们会根据数据访问成本和风险采用 IP 级限流或 handler 内授权/签名验证（[`model_plaza.go:23`](../../backend/internal/server/routes/model_plaza.go#L23)、[`payment.go:71`](../../backend/internal/server/routes/payment.go#L71)）。

### 4.3 网关请求的准入与转发链

以 `/v1` 为例，路由组依次挂载请求体大小限制、客户端请求 ID、运维错误记录、入口路径规范化、API Key 认证、分组模型 allowlist、composite 路由决策和协议/分组要求（[`gateway.go:180`](../../backend/internal/server/routes/gateway.go#L180) 至 [`gateway.go:189`](../../backend/internal/server/routes/gateway.go#L189)）。`/v1beta` 使用 Google 兼容的 Key/订阅认证适配器，再进入相应的 allowlist、路由决策和平台校验（[`gateway.go:338`](../../backend/internal/server/routes/gateway.go#L338) 至 [`gateway.go:346`](../../backend/internal/server/routes/gateway.go#L346)）。

关键约束：

1. 模型 allowlist 在 composite 改写之前运行，使准入判断针对客户端提交的模型名（顺序在 [`gateway.go:187`](../../backend/internal/server/routes/gateway.go#L187) 和 [`gateway.go:188`](../../backend/internal/server/routes/gateway.go#L188)）。
2. composite route 可以依据 API Key 所属分组和模型解析目标平台/上游模型，并把路由决策放入 request context；协议特有的 URL/参数处理依然由对应 handler/service 承担（[`gateway.go:549`](../../backend/internal/server/routes/gateway.go#L549)、[`gateway.go:613`](../../backend/internal/server/routes/gateway.go#L613)）。
3. 未分配分组的 Key 使用对应协议格式返回拒绝响应（[`gateway.go:32`](../../backend/internal/server/routes/gateway.go#L32) 至 [`gateway.go:36`](../../backend/internal/server/routes/gateway.go#L36)）。
4. 图像、视频、语音、embeddings 等端点还会执行平台级能力判定；不支持时返回协议兼容的 Not Found，而不是把请求任意转给其他平台（例如 [`gateway.go:49`](../../backend/internal/server/routes/gateway.go#L49)、[`gateway.go:76`](../../backend/internal/server/routes/gateway.go#L76)、[`gateway.go:92`](../../backend/internal/server/routes/gateway.go#L92)）。
5. `usage`、Key billing 和部分异步任务查询在认证之外允许跳过相应计费封锁，便于额度耗尽后查询自身状态；这不等于跳过身份认证。

### 4.4 项目中同类功能的实现方式与数量

以下数量按明确列出的源码模式统计，不把不同抽象层级的概念混作一种实现：

| 同类功能        | 实现方式数量 | 项目采用的方式                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --------------- | -----------: | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 启动流程        | 4 条主要路径 | 版本输出退出、CLI Setup、Setup HTTP、常规 HTTP；首次启动 auto-setup 是常规服务路径的预初始化分支（[`main.go:64`](../../backend/cmd/server/main.go#L64) 至 [`main.go:94`](../../backend/cmd/server/main.go#L94)）。                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| 路由组织 / 注册 |     4 种模式 | ① 按功能域调用 registrar；② `RouterGroup` 嵌套及继承中间件；③ Gin Engine 直接注册根路径；④ `rootRoute` helper 为单条别名路由统一组装中间件链（[`router.go:117`](../../backend/internal/server/router.go#L117) 至 [`router.go:134`](../../backend/internal/server/router.go#L134)、[`admin.go:26`](../../backend/internal/server/routes/admin.go#L26)、[`common.go:12`](../../backend/internal/server/routes/common.go#L12)、[`gateway.go:370`](../../backend/internal/server/routes/gateway.go#L370)）。                                                                                                                                                                             |
| 认证上下文      |         3 类 | 用户 JWT、管理员身份、用户 API Key；管理员身份进一步有 3 种凭证机制，API Key 支持 3 种 header 传递形式，具体见 4.1（[`jwt_auth.go:40`](../../backend/internal/server/middleware/jwt_auth.go#L40)、[`admin_auth.go:27`](../../backend/internal/server/middleware/admin_auth.go#L27)、[`api_key_auth.go:58`](../../backend/internal/server/middleware/api_key_auth.go#L58)）。                                                                                                                                                                                                                                                                                                                   |
| 网关平台决策    |     4 种机制 | ① 根据分组平台自动选择 handler；② `ForcePlatform` 固定平台；③ endpoint 平台能力 gate；④ composite route resolver 解析目标平台/模型。Gemini 的专用认证适配器属于协议认证差异，不另算平台分派机制（[`gateway.go:49`](../../backend/internal/server/routes/gateway.go#L49)、[`gateway.go:193`](../../backend/internal/server/routes/gateway.go#L193)、[`gateway.go:76`](../../backend/internal/server/routes/gateway.go#L76)、[`gateway.go:499`](../../backend/internal/server/routes/gateway.go#L499)、[`gateway.go:549`](../../backend/internal/server/routes/gateway.go#L549)、[`api_key_auth_google.go:25`](../../backend/internal/server/middleware/api_key_auth_google.go#L25)）。 |
| 支付访问控制    |     4 类入口 | 登录用户 JWT、匿名公开查询（其中验证接口有 IP 限流）、支付 webhook（由支付业务验证）、管理员认证；这四类有不同的授权信任边界（[`payment.go:40`](../../backend/internal/server/routes/payment.go#L40)、[`payment.go:71`](../../backend/internal/server/routes/payment.go#L71)、[`payment.go:80`](../../backend/internal/server/routes/payment.go#L80)、[`payment.go:92`](../../backend/internal/server/routes/payment.go#L92)）。                                                                                                                                                                                                                                                              |
| 页面资源授权    |     3 种处理 | 页面内容要求用户 JWT 并校验可见性；页面图片不要求 JWT、在 handler 校验可见性；页面管理列表要求管理员认证及合规确认（[`page_handler.go:265`](../../backend/internal/handler/page_handler.go#L265) 至 [`page_handler.go:284`](../../backend/internal/handler/page_handler.go#L284)）。                                                                                                                                                                                                                                                                                                                                                                                                            |

路由注册统计的是结构模式，而非不同 Gin API 的语法计数；平台决策统计的是 handler/target 的选择逻辑，不包括同一 handler 被映射到多个路径的兼容别名。支付 webhook 的身份验证发生在回调业务逻辑中，不能误读为“无认证即可信”。

## 5. Handler、Service 与路由职责

`handler.Handlers` 是 HTTP handler 依赖的聚合结构，按领域聚合 Auth、User、APIKey、Usage、Payment、Gateway、AsyncImage、BatchImage、ChannelMonitor 等处理器；`AdminHandlers` 进一步聚合 Dashboard、User、Group、Account、Ops、Setting、Backup、Plugin 等后台处理器（[`handler.go:9`](../../backend/internal/handler/handler.go#L9)、[`handler.go:49`](../../backend/internal/handler/handler.go#L49)）。

典型请求的职责分工：

```text
Gin route / middleware
  ├─ 路径、HTTP method、认证、限流、审计和协议准入
  └─ handler
       ├─ 解析/校验 HTTP 输入，组织响应和错误映射
       └─ service
            ├─ 业务策略、权限、调度、计费、事务边界
            └─ repository / Ent / Redis / 外部 provider
```

路由注册器应保持薄层：声明路径、HTTP method、路由组中间件和 handler。不要在 route closure 中复制完整业务流程；如需协议 dispatch 或路径差异处理，应抽取清晰的 helper，并在对应路由测试中验证。

## 6. 关键功能域的边界说明

### 6.1 账号、分组与模型调度

管理员 `/accounts` 维护上游账号及凭证、可用性、状态、额度、可用模型和批量刷新；`/groups` 管理客户端 Key 的策略承载单元，包括平台、模型 allowlist、速率/价格倍率、容量和 composite route（[`admin.go:329`](../../backend/internal/server/routes/admin.go#L329)、[`admin.go:360`](../../backend/internal/server/routes/admin.go#L360)）。网关在认证后依照这些信息确定模型是否准入、选择何种协议 handler 以及可路由到何处（[`gateway.go:187`](../../backend/internal/server/routes/gateway.go#L187) 至 [`gateway.go:189`](../../backend/internal/server/routes/gateway.go#L189)）。

### 6.2 用量、结算与支付

用户 `/usage` 面向个人用量查询；管理员 `/usage`、`/dashboard`、`/ops` 分别偏向管理查询、聚合分析和实时运行信号（[`user.go:99`](../../backend/internal/server/routes/user.go#L99)、[`admin.go:193`](../../backend/internal/server/routes/admin.go#L193)、[`admin.go:283`](../../backend/internal/server/routes/admin.go#L283)、[`admin.go:707`](../../backend/internal/server/routes/admin.go#L707)）。`/payment` 提供套餐、订单与用户退款申请，`/payment/webhook` 对接第三方支付异步通知，`/admin/payment` 承担订单履约、退款和支付配置（[`payment.go:40`](../../backend/internal/server/routes/payment.go#L40)、[`payment.go:80`](../../backend/internal/server/routes/payment.go#L80)、[`payment.go:92`](../../backend/internal/server/routes/payment.go#L92)）。订阅生命周期另外由用户 `/subscriptions` 和管理员 `/admin/subscriptions` 管理（[`user.go:130`](../../backend/internal/server/routes/user.go#L130)、[`admin.go:684`](../../backend/internal/server/routes/admin.go#L684)）。

### 6.3 运维、审计与安全能力

`/admin/ops` 汇总请求失败、上游错误、系统日志、ingress rejection、告警和实时指标；`/admin/audit-logs` 记录管理端操作；`/admin/prompt-audit` 与 `/admin/risk-control` 管理内容风险/审计（[`admin.go:193`](../../backend/internal/server/routes/admin.go#L193)、[`admin.go:154`](../../backend/internal/server/routes/admin.go#L154)、[`admin.go:138`](../../backend/internal/server/routes/admin.go#L138)、[`admin.go:172`](../../backend/internal/server/routes/admin.go#L172)）。它们各自语义不同，排障时应根据事件发生阶段选择对应数据源。

Step-up 不是另一种管理员身份，而是已认证管理员会话对高影响操作的再验证门槛；路由对敏感 endpoint 显式增加该中间件，部分操作则在 handler 内强制现场 TOTP（示例见 [`custom_admin_keys.go:13`](../../backend/internal/server/routes/custom_admin_keys.go#L13)、[`admin.go:419`](../../backend/internal/server/routes/admin.go#L419)）。添加敏感写接口时必须检查既有模块的保护方式并沿用。

## 7. 维护与扩展建议

### 新增面板 API

1. 在匹配的 `backend/internal/server/routes/*.go` 注册器中声明 endpoint，不要直接塞入总装配函数。
2. 明确接口是公开、用户 JWT 还是管理员身份；公开入口仍需评估 IP 限流。
3. 选择既有用户/管理员组，以继承运行模式 guard、审计和限流；敏感操作单独评估 step-up。
4. 输入校验和领域规则放在 handler/service，而不是以匿名 route closure 承载业务状态。
5. 补充 handler/service 测试以及 route/middleware 覆盖，重点覆盖未认证、权限不足、运行模式、速率限制和错误协议。

### 新增模型网关 API

1. 确认客户端协议、规范路径和兼容别名；明确请求体上限及 streaming/WebSocket 行为。
2. 确认适用认证器、计费例外、API Key 分组要求、model allowlist 和平台能力限制。
3. 对 composite group 明确模型提取位置、endpoint 分类和目标平台回退策略。
4. 复用或扩展协议 handler/service，不要仅以 URL 前缀决定上游类型。
5. 为参数改写、模型别名、上游错误和 Ops 归因分别测试，并校验协议返回结构。

### 路由冲突与变更控制

- Gin 的参数段与 catch-all（`:param`、`*path`）会影响注册顺序及匹配覆盖；新增 catch-all 时检查同一前缀的静态路径是否会冲突。
- `/api/v1` 面板路由与根路径网关路由是不同安全边界。移动路径或改变注册器可能改变认证中间件，必须按安全敏感变更审查。
- 修改 handler 结构体时同步检查 Wire provider；依赖构建失败通常意味着 provider set 或生成代码需要更新。
- 模型平台能力、订阅/计费例外和 composite fallback 属于业务策略；不能通过添加一条路由来绕过这些政策。
- 当前 router 以代码注册为事实来源；若未来引入 OpenAPI/自动路由清单，应将其与 Gin 实际注册集合建立可验证的一致性检查。

## 8. 代码索引

以下路径相对于仓库根目录：

| 文件                                                                                        | 职责                                              |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| [`main.go:55`](../../backend/cmd/server/main.go#L55)                                       | 版本/Setup/常规启动分支、监听与优雅关闭           |
| [`wire.go:34`](../../backend/cmd/server/wire.go#L34)                                       | 应用依赖集合及清理资源组装                        |
| [`http.go:30`](../../backend/internal/server/http.go#L30)                                  | Gin Engine、trusted proxies、HTTP Server provider |
| [`router.go:23`](../../backend/internal/server/router.go#L23)                              | 全局中间件及各 route registrar 总装配             |
| [`common.go:10`](../../backend/internal/server/routes/common.go#L10)                       | 健康、Setup 状态和事件兼容入口                    |
| [`auth.go:16`](../../backend/internal/server/routes/auth.go#L16)                           | 面板认证及 OAuth 路由                             |
| [`user.go:12`](../../backend/internal/server/routes/user.go#L12)                           | 当前用户、Key、用量、订阅、监控等面板 API         |
| [`admin.go:14`](../../backend/internal/server/routes/admin.go#L14)                         | 管理端模块聚合和功能域路由                        |
| [`custom_admin_keys.go:10`](../../backend/internal/server/routes/custom_admin_keys.go#L10) | Scoped Admin Key 生命周期路由                     |
| [`payment.go:27`](../../backend/internal/server/routes/payment.go#L27)                     | 用户、匿名、webhook 和管理员支付路由              |
| [`model_plaza.go:16`](../../backend/internal/server/routes/model_plaza.go#L16)             | 可选 JWT 的模型广场查询                           |
| [`gateway.go:22`](../../backend/internal/server/routes/gateway.go#L22)                     | 多协议 API 网关、兼容别名和模型平台 dispatch      |
| [`page_handler.go:261`](../../backend/internal/handler/page_handler.go#L261)               | 页面内容/图片访问判定和页面路由                   |
| [`handler.go:9`](../../backend/internal/handler/handler.go#L9)                             | HTTP handler 聚合结构                             |
| [`jwt_auth.go:40`](../../backend/internal/server/middleware/jwt_auth.go#L40)               | 用户 JWT 认证                                     |
| [`admin_auth.go:27`](../../backend/internal/server/middleware/admin_auth.go#L27)           | 管理员 JWT/API Key/Scoped Key 认证                |
| [`api_key_auth.go:54`](../../backend/internal/server/middleware/api_key_auth.go#L54)       | API Key 与订阅/计费检查                           |
