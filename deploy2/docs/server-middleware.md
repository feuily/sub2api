# Server 中间件架构、执行链与扩展指南

本文说明 Sub2API 后端 HTTP server 中间件的分层、全局执行顺序、认证/授权、网关专用链、上下文数据传递、错误/审计/限流，以及如何安全地新增中间件。内容以当前 `backend/internal/server` 和关联代码为准。

本文所称“中间件”不只指 `internal/server/middleware` 目录中的 `gin.HandlerFunc`，还包括路由组上挂载的 handler 包装函数、协议入口预处理和 `internal/middleware` 的通用 Redis 限流器。读代码时要先确认中间件注册在哪一层，否则容易误判作用范围和执行顺序。

## 1. 目录边界和核心概念

### 1.1 三个常见位置

| 位置 | 职责 | 例子 |
| --- | --- | --- |
| [`internal/server/middleware/`](../../backend/internal/server/middleware/) | Gin HTTP 层的通用请求处理、认证授权、审计、安全头、网关准入等。 | JWT、API key、CORS、SessionBindingContext、GroupModelAllowlist |
| [`internal/server/routes/`](../../backend/internal/server/routes/) | 将中间件按 URL/方法组合到 route/group，定义保护边界。 | `/api/v1/admin` 的认证、审计、合规链；`/v1` 网关链 |
| [`internal/middleware/`](../../backend/internal/middleware/) | 不专属于 server middleware 包的基础设施型中间件/组件；当前 Redis 限流器由 route 层创建并挂载。 | `RateLimiter`、`LimitWithOptions` |

此外，部分路由中间件由其他包提供：如网关请求错误日志 `handler.OpsErrorLoggerMiddleware`、入站端点归一化、Composite 目标解析和平台转换。它们虽然也是 `gin.HandlerFunc`，但不在 `server/middleware/` 下。

### 1.2 Gin 中间件执行模型

中间件通常是：

```go
func Middleware(...) gin.HandlerFunc {
    return func(c *gin.Context) {
        // 请求前处理
        c.Next()
        // 请求后处理
    }
}
```

- 同一 engine/group 注册的 middleware 按注册顺序进入；调用 `c.Next()` 时运行后续 middleware 和 handler，返回后再执行当前 middleware 的后置逻辑。
- `c.Abort()` / `AbortWithStatusJSON()` 中止后续链，不会自动回滚已写入的响应或数据库状态。
- 认证 middleware 通常先写入 Gin context 或 `Request.Context()`，之后授权/handler 才能读取。
- 具体 route middleware 不是“自动全局生效”：只有在对应 `r.Use`、`group.Use` 或单条 route 注册中出现才会执行。

## 2. Router 构造与全局执行顺序

### 2.1 构造阶段

1. [`server/http.go:30`](../../backend/internal/server/http.go#L30) 的 `ProvideRouter` 创建 `gin.New()`。
2. 先注册 [`Recovery`](../../backend/internal/server/middleware/recovery.go#L19)，并调用 `configureTrustedProxies` 设置 Gin 的可信代理策略。
3. 调用 [`SetupRouter`](../../backend/internal/server/router.go#L23)：
   - 注册请求 ID、会话绑定、访问日志、CORS、安全响应头、Server-Timing；
   - 设置前端 embed/settings callback；
   - 将 common、auth、user、admin、gateway、payment、page routes 挂载到 router。
4. [`server/http.go:113`](../../backend/internal/server/http.go#L113) 再把 Gin router 放入标准库 `http.Server`，可按配置添加全局最大 request body 限制和 h2c。

### 2.2 正式服务全局 middleware 顺序

按源码的注册顺序，正式 router 的外围链是：

```text
Recovery
  └─ RequestLogger
      └─ SessionBindingContext
          └─ Logger
              └─ CORS
                  └─ SecurityHeaders
                      └─ ServerTiming
                          └─ route-group middleware
                              └─ handler
```

关键位置：

- `Recovery`：[`server/http.go:51`](../../backend/internal/server/http.go#L51)
- 全局 `r.Use` 顺序：[`server/router.go:59-71`](../../backend/internal/server/router.go#L59)
- 可信代理配置：[`server/http.go:93`](../../backend/internal/server/http.go#L93)
- route 汇总：[`server/router.go:99`](../../backend/internal/server/router.go#L99)
- 标准 HTTP server 和 body limit：[`server/http.go:113`](../../backend/internal/server/http.go#L113)

Recovery 在 `SetupRouter` 的 middleware 之前注册，因此它位于整体请求栈外侧，能够捕获后续 middleware/handler 的 panic。

### 2.3 各全局 middleware 做什么

| middleware | 源码 | 作用与边界 |
| --- | --- | --- |
| `Recovery()` | [`recovery.go:19`](../../backend/internal/server/middleware/recovery.go#L19) | 将 panic 转为统一 500 JSON 错误；如果响应已写出则只 abort，不尝试覆盖响应；broken pipe / client reset 不再向已断开的连接写错误响应。 |
| `RequestLogger()` | [`request_logger.go:17`](../../backend/internal/server/middleware/request_logger.go#L17) | 规范化或生成 `X-Request-ID`，写入响应 header 和 request context，并构造 request-scoped logger，供后续日志关联。 |
| `SessionBindingContext(cfg)` | [`session_binding.go:18`](../../backend/internal/server/middleware/session_binding.go#L18) | 根据可信代理配置解析安全客户端 IP、清理/截断 User-Agent，并将 session binding 放入 request context。JWT 签发和校验应使用同一来源。 |
| `Logger()` | [`logger.go:14`](../../backend/internal/server/middleware/logger.go#L14) | `c.Next()` 后记录访问日志、状态码、耗时、IP、协议以及可用的 account/platform/model 维度；`/health`、`/setup/status` 不记常规访问日志。还处理 ingress 拒绝聚合和日志采样。 |
| `CORS(cfg.CORS)` | [`cors.go:16`](../../backend/internal/server/middleware/cors.go#L16) | 按允许 origin 写 CORS headers；OPTIONS 预检会在 middleware 内结束。`*` 与 credentials 不能同时启用，代码会关闭 credentials 并记录警告。 |
| `SecurityHeaders(...)` | [`security_headers.go:111`](../../backend/internal/server/middleware/security_headers.go#L111) | 设置 `X-Content-Type-Options`、`X-Frame-Options` 和 `Referrer-Policy`；非 API 页面可按 CSP 配置生成 nonce，并合并必需的外部资源域名与动态 frame origins。API 路径按实现不设置 CSP。 |
| `ServerTiming(enabled)` | [`server_timing.go:29`](../../backend/internal/server/middleware/server_timing.go#L29) | 配置启用时收集管理 UI/用户 UI 范围内的计时，并在通过身份/路径检查后生成 `Server-Timing`。请求头只表示 UI 作用范围，不构成认证。 |

Request ID 的边界长度和 UTF-8 规范化在 [`request_metadata.go:15`](../../backend/internal/server/middleware/request_metadata.go#L15)。`X-Request-ID` 是服务端 trace/correlation id；网关另有 `X-Client-Request-ID`，不要把二者混为一谈。

### 2.4 重要的外层限制：不是 Gin middleware

`ProvideHTTPServer` 可把 router 包装为 `http.MaxBytesHandler`。这是 Gin 外层的标准库 handler wrapper：

- `server.max_request_body_size` 优先；
- 未配置时回退 `gateway.max_body_size`；
- Gateway routes 又可使用自己的 `RequestBodyLimit`，特定 endpoint 还有 text body 上限。

如果 HTTP 全局 max body 被超过，底层 handler 会返回错误；route middleware 的 `RequestBodyLimit` 则通过 `http.MaxBytesReader` 让下游读取请求体时得到 `MaxBytesError`。排查 413 时需要确认命中的是哪一层。不要只在 handler 中无限制地 `io.ReadAll`。

## 3. 认证与授权 middleware

认证回答“请求凭据是谁/是否有效”；授权回答“该身份是否能访问当前资源/动作”。当前项目存在 JWT、可选 JWT、管理员凭证和 gateway API key 等不同认证方式，它们不应互相替代。

### 3.1 JWT：用户会话

实现入口：[`jwt_auth.go:14`](../../backend/internal/server/middleware/jwt_auth.go#L14)。

严格 JWT 链主要执行：

1. 读取 `Authorization: Bearer <token>`；
2. 验证 token 和过期时间；
3. 从数据库重新读取用户，而不是只信 token claim；
4. 检查用户 active 状态和 `TokenVersion`，支持改密/撤销后拒绝旧 token；
5. 按系统开关执行 IP/User-Agent session binding 校验；
6. 把 `AuthSubject`、role、email、session ID 写入 Gin context；
7. 触碰 last-active，调用 `c.Next()`。

认证成功后的共享读取 helper 在 [`auth_subject.go:12`](../../backend/internal/server/middleware/auth_subject.go#L12) 和 [`auth_subject.go:21`](../../backend/internal/server/middleware/auth_subject.go#L21)。添加依赖身份的 middleware 时优先使用 helper，不要自行解析或信任客户端传来的 user ID。

### 3.2 Optional JWT：匿名或登录用户

实现入口：[`optional_jwt_auth.go:16`](../../backend/internal/server/middleware/optional_jwt_auth.go#L16)。

- 没有 `Authorization`：匿名放行，不创建认证主体。
- header 存在：委托严格 JWT 链；token 无效、过期或 session binding 不符都返回 401，不会静默降级匿名。

适合公开内容可选显示“当前用户个性化信息”的 endpoint。不能用于要求必须登录的资源。

### 3.3 管理员认证：JWT、管理 API key 与受限管理 key

实现入口：[`admin_auth.go:16`](../../backend/internal/server/middleware/admin_auth.go#L16)。

支持的认证分支包括：

- JWT：验证 token、用户状态、TokenVersion 和 session binding，并要求管理员角色。
- 传统管理员 API key：读取配置中的 admin key，使用 constant-time compare 验证；再关联实际管理员主体。
- `adm_sc_` scoped admin key：通过 SettingService 校验 key、创建者状态、IP 等，并按路由 method/path policy 做 allowlist 检查；未授权默认拒绝。它会写入专用 principal context，供资源级授权/限流读取。
- WebSocket admin endpoint：浏览器无法在 upgrade 设置普通 Authorization 时，可在 `Sec-WebSocket-Protocol` 的 `jwt.<token>` 子项提供 JWT；仍走管理员 JWT 校验。

`x-api-key` 不代表普通 gateway API key；在 `/api/v1/admin` 下它用于管理员 API key。受限 key 不能管理 admin API key 配置等敏感管理项，并通过专门审计流程记录请求。普通用户角色检查的简单 middleware `AdminOnly()` 位于 [`admin_only.go:11`](../../backend/internal/server/middleware/admin_only.go#L11)，但具体 admin routes 通常使用完整 `AdminAuthMiddleware`。

### 3.4 Gateway API key：认证、分组和计费门控

入口：[`api_key_auth.go:21`](../../backend/internal/server/middleware/api_key_auth.go#L21)；Gemini 原生错误格式版本：[`api_key_auth_google.go:25`](../../backend/internal/server/middleware/api_key_auth_google.go#L25)。

主 gateway API-key middleware 的职责不止凭据验证，当前链还会处理：

1. 无效认证尝试保护及凭证头长度限制；
2. 从 Bearer、`x-api-key` 或 `x-goog-api-key` 读取 key；禁止通用 OpenAI/Anthropic gateway 使用 `key`/`api_key` query 凭证；
3. 查找 API key，识别认证过载；
4. 验证 key、用户、分组状态、分组授权和 key IP ACL；
5. 标记运维错误日志的 fallback API key 信息；
6. 按 RunMode、endpoint、key 状态、订阅限额和余额执行计费/访问判断；
7. 把 API key、用户、role、group、subscription 等主体写入 context；
8. 更新 key last-used 时间并继续请求。

`/v1/usage`、`/v1/sub2api/billing` 和异步图片任务读取端点对已认证 key 跳过部分计费门控，保证额度耗尽后仍能读取自身用量/任务结果；这不等于跳过基础认证、用户状态或 IP ACL。`simple` RunMode 会跳过常规 billing/quota 检查，属于明确的运行模式语义。

Gemini 原生 `APIKeyAuthWithSubscriptionGoogle` 具有 Google 风格错误响应，且 query `api_key` 被拒绝；需与通用协议入口的 header/query 行为分别确认。使用该 middleware 时不要换成通用错误格式，否则 SDK 兼容性可能变化。

### 3.5 Step-up 2FA：敏感管理操作的二次认证

实现入口：[`step_up.go:48`](../../backend/internal/server/middleware/step_up.go#L48)。

当 `step_up_enabled` 打开时，访问受保护动作需要：

- 有 JWT 认证主体；
- 不是 admin API key 机器凭证；
- 用户已启用 TOTP；
- 当前 token session（旧 token fallback 到 user key）在有效窗口内有 step-up grant。

管理 API key 被拒绝是设计行为：step-up 验证证明近期真人持有第二因素，而不是机器 key 的权限。系统开关关闭时 middleware 放行，以保持兼容；settings 缺失时按 fail-closed 处理。部分 handler 会对依请求内容触发的敏感动作调用 `EnforceStepUp`/`EnforceStepUpAlways`，不一定只在 routes 上挂 middleware。

### 3.6 Backend mode 与合规门控

- [`BackendModeAuthGuard`](../../backend/internal/server/middleware/backend_mode_guard.go#L80)：backend mode 开启时阻止注册和不允许的用户 auth flow，但放行管理员仍需的登录、回调及 refresh 等路径。
- [`BackendModeUserGuard`](../../backend/internal/server/middleware/backend_mode_guard.go#L14)：必须放在 JWT 认证之后；非管理员自助服务被关闭，管理员放行。
- [`AdminComplianceGuard`](../../backend/internal/server/middleware/admin_compliance.go#L12)：要求已认证管理员完成当前合规确认；compliance endpoint 自身 bypass，避免无法进入确认页面的死锁。

这些是业务访问策略，不要因为名字带 “Guard” 就当作身份认证。它们通常必须附着在恰当 route group 并位于认证之后。

## 4. 审计、日志和运维拒绝观测

### 4.1 管理/用户操作审计

实现入口：[`audit_log.go:166`](../../backend/internal/server/middleware/audit_log.go#L166)。

审计中间件当前关注：

- 所有 POST/PUT/PATCH/DELETE；
- 少量显式 allowlist 的敏感 GET；
- action 可使用精确 override，否则根据 method 和 route template 推导；
- 回填请求 body 以不影响后续 handler binding；使用 service 的脱敏规则，凭据密集的特殊路由整体省略 body；
- 记录 method、route、status、latency、request ID、client IP、actor、auth method、masked credentials、已脱敏 query 和受 allowlist 限制的 scalar extras；
- refresh token 成功属于高频常规操作，只记录失败。

`SetAuditAction`、`SetAuditActor`、`SkipAudit`、`SetAuditExtra` helper 分别位于 [`audit_log.go:32`](../../backend/internal/server/middleware/audit_log.go#L32)、[`audit_log.go:37`](../../backend/internal/server/middleware/audit_log.go#L37)、[`audit_log.go:47`](../../backend/internal/server/middleware/audit_log.go#L47)、[`audit_log.go:65`](../../backend/internal/server/middleware/audit_log.go#L65)。

挂载位置影响覆盖范围：

- `/api/v1/admin` 与普通用户组：审计 middleware 在认证后，因此未通过身份认证的 401/403 通常不会进入该 middleware 的操作审计。
- `/api/v1/auth`：公开认证组没有前置 JWT，登录/注册/刷新失败尝试也可以被审计。
- scoped admin key 有自己单独的逐请求审计记录，认证代码会设置 skip 标记避免重复记录。

审计不是访问日志的替代品。不得在 audit extras 或 handler 中放 API key/token、密码、完整 OAuth credential 或任意请求体。

### 4.2 访问日志、Request ID 与 `ClientRequestID`

- `RequestLogger` 创建/校验服务端 `X-Request-ID` 和 request-scoped logger。
- gateway 中 [`ClientRequestID()`](../../backend/internal/server/middleware/client_request_id.go#L19) 确保有 client correlation ID，并通过 `X-Client-Request-ID` 返回；外部请求没带已有 context ID 时当前实现会生成 UUID。
- `Logger()` 在请求后记录 access log，跳过高频 health 路径。
- 对预期 ingress 拒绝，先调用 `MarkIngressRejected` 标记原因，再在 Logger 里记录聚合计数；每进程常规拒绝 access log 固定窗口最多 20 条/秒，超过后周期性汇报 dropped count，避免被无效认证流量打爆日志。
- [`ingress_reject.go`](../../backend/internal/server/middleware/ingress_reject.go#L76) 绑定运维拒绝 recorder；[`MarkIngressRejected`](../../backend/internal/server/middleware/ingress_reject.go#L85) 标记原因。

拒绝的请求仍可写普通 access log，但会标注业务拒绝原因且避免计为普通 ops error；采样只影响 access log，不应被误解为拒绝计数/安全检测也被采样掉。

### 4.3 client IP 的安全边界

项目中存在多种客户端 IP API，使用场景不同：

- Gin `ClientIP()` 受可信代理设置影响；
- 安全 ACL、session binding、审计与某些 rate limit 使用安全 IP helper；
- `SessionBindingContext` 会根据配置决定信任哪些转发头，并把解析结果写入 request context；
- `configureTrustedProxies` 在 Gin router 层设置代理网段。生产反向代理应配置正确可信代理，不要信任任意来源可控的 `X-Forwarded-For`。

不要在 middleware 中自行读取 `X-Forwarded-For` 来做授权或 key ACL。应复用 `SecurityClientIP`/`internal/pkg/ip` 约定，以避免审计、会话绑定、限流和 ACL 看到不同客户端地址。

## 5. 限流器：两类不同组件

### 5.1 Auth / route 使用的通用 Redis `RateLimiter`

实现：[`internal/middleware/rate_limiter.go:70`](../../backend/internal/middleware/rate_limiter.go#L70)。

- 使用 Redis Lua `INCR` + TTL 固定窗口计数，跨进程共享限额；
- `LimitWithOptions` 通常按 route key + 安全客户端 IP 计数；
- 可选 `RateLimitFailOpen` 或 `RateLimitFailClose`；
- 超限返回 429 和 `Retry-After`；
- 认证、注册、登录、密码重置等高风险入口使用 fail-close：Redis 不可用时阻止请求；
- 普通保护策略可按其调用方选 fail-open。

它位于 `internal/middleware`，由 routes 显式创建/挂载，不属于全局 `server/middleware`。

### 5.2 PanelRateLimiter

实现：[`panel_rate_limit.go:44`](../../backend/internal/server/middleware/panel_rate_limit.go#L44)。

- `Global()`：登录主体按 user ID 计数；受限 admin key 按 key ID 计数；可以配置管理员豁免。
- `Heavy()`：usage/dashboard 等重查询更严格；一般叠加在 Global 限额上。
- `PublicIP()`：无需认证的公开 UI API 按安全公网 IP 计数；loopback/private/link-local 等代理内部地址不参与计数，以免所有请求塌缩到反向代理 IP 后集体被限。
- 限流配置通过 SettingService 的进程内缓存读取，热路径不逐请求查数据库。
- Redis 出错时该面板 limiter fail-open 并告警，避免保护机制变成整个面板故障。

具体端点是否 Global+Heavy、匿名请求是否 PublicIP，需要以 route 注册为准。

## 6. Gateway 专用中间件链

Gateway routes 不仅做 API key 认证，还需保持 body、request ID、错误日志、平台/模型解析顺序。入口示例在 [`routes/gateway.go:22`](../../backend/internal/server/routes/gateway.go#L22)。

### 6.1 通用 `/v1` 链

[`routes/gateway.go:181-189`](../../backend/internal/server/routes/gateway.go#L181) 的 `/v1` 链大意如下：

```text
RequestBodyLimit
  -> ClientRequestID
  -> OpsErrorLoggerMiddleware
  -> InboundEndpointMiddleware
  -> APIKeyAuthMiddleware
  -> GroupModelAllowlist
  -> Composite target/platform resolver
  -> RequireGroupAssignment (Anthropic-style error)
  -> endpoint handler
```

`GET /v1/sub2api/billing` 在模型白名单/Composite/未分组 middleware 之前单独注册，因此没有必要的请求模型时可读取 key billing info；API key auth 自己仍识别它为 billing-info endpoint 并采用相应的 billing skip 规则。

### 6.2 Gemini 原生链

[`routes/gateway.go:339-346`](../../backend/internal/server/routes/gateway.go#L339) 的 `/v1beta` 类入口使用：

```text
body limit -> client request ID -> ops error logging -> endpoint normalize
  -> Google-style API-key auth
  -> group model allowlist
  -> Gemini Composite target resolution
  -> RequireGroupAssignment (Google-style error)
  -> handler
```

Anthropic、OpenAI-compatible、Google native 的错误 envelope 不能随意混用；认证失败或模型拒绝可能发生在 handler 之前，所以 middleware 必须按入口协议写正确响应。

### 6.3 请求体限制与读取/回填

[`RequestBodyLimit`](../../backend/internal/server/middleware/request_body_limit.go#L10) 用 `http.MaxBytesReader` 包装 request body。Gateway routes 根据配置创建通用和 text-only limits；某些中间件（例如模型白名单）需预读 JSON/multipart 的 model：

- 预读后要通过项目请求模型/body helper 回填 body，确保 handler 还能读取；
- 读取上限错误应返回 413，而不是把空/截断 body 当正常请求；
- multipart/body parser 要考虑重复字段、大小写兼容与下游实际绑定语义；
- 不要把完整 body 写进日志或 error message。

### 6.4 GroupModelAllowlist 必须在 Composite 改写之前

实现：[`group_model_allowlist.go:32`](../../backend/internal/server/middleware/group_model_allowlist.go#L32)。

它的职责：

- 先从已认证 API key 的 group 读取 allowlist；未绑定 group 或未开启时快速放行；
- 从路由参数、query 或 JSON/multipart body 提取客户端公开模型名；
- 同时校验下游解析器可能绑定到的候选模型，避免重复 JSON 字段/大小写差异造成绕过；
- Responses WebSocket 的模型在升级后帧中，所以只对确切 WebSocket routes 交由 handler 逐帧检查；
- 拒绝时标记 ops 业务限流原因和 ingress reject reason，并按 Anthropic/Google/OpenAI 入口返回对应格式。

注册顺序必须保持在 Composite target/platform middleware **之前**：先检查客户端写的公开模型名，再改写为 Composite 目标模型。如果挪到 Composite 解析之后，校验对象可能变成内部目标模型，语义和安全边界都会变。

### 6.5 RequireGroupAssignment 与协议错误适配

实现位于 [`middleware.go:143`](../../backend/internal/server/middleware/middleware.go#L143)。当 API key 没有关联 group 且系统设置不允许 ungrouped key 调度时拒绝，并标记 ingress reject reason。

函数接受 `GatewayErrorWriter`，可为 Anthropic、Google、OpenAI-compatible 入口生成各自错误 envelope。新增 gateway 协议入口时，要同时明确：

- API key auth 的凭证输入方式；
- endpoint/model 的解析方式；
- group/平台检查；
- 错误 envelope；
- 计费/订阅行为；
- 模型白名单和 Composite 的顺序。

## 7. 路由级保护链举例

### 7.1 `/api/v1/auth`

见 [`routes/auth.go:16`](../../backend/internal/server/routes/auth.go#L16)：

- backend mode auth guard；
- auth event audit；
- 注册、登录、2FA、passkey、发送验证码、refresh 等 route 各自挂 Redis rate limit；
- 高风险 auth limiter 明确用 fail-close；
- 这个 group 没有预先 JWT auth，因此支持记录登录失败。

### 7.2 用户 API

见 [`routes/user.go:12`](../../backend/internal/server/routes/user.go#L12)：

```text
JWTAuth -> BackendModeUserGuard -> PanelRateLimiter.Global -> AuditLog
```

usage、部分 dashboard/monitor 路由再叠加 `Heavy()`。如果新增用户 API，不能只加 handler，要确认它是否应纳入 `authenticated` group，是否需要 Heavy limit，以及读请求是否属于敏感审计 allowlist。

### 7.3 管理 API

见 [`routes/admin.go:14`](../../backend/internal/server/routes/admin.go#L14)：

```text
AdminAuth -> PanelRateLimiter.Global -> AuditLog -> AdminComplianceGuard
  -> ScopedAdminKey resource policy -> route-specific guards -> handler
```

管理路由下有按功能 scope 的专用资源规则；敏感动作可单独加 step-up。添加一个 admin endpoint 时需同时评估普通管理员和 scoped admin key 的授权范围，不能只做“已是管理员”的全局判断。

例如备份创建、恢复、下载链接和 S3 destination 更改在 [`routes/admin.go:650-675`](../../backend/internal/server/routes/admin.go#L650) 附近单独挂 StepUp middleware。

### 7.4 公共/可选登录 route

Model plaza 可按配置的 public IP rate limit，并使用 optional JWT；之后 backend mode guard 决定该模式下是否可用。支付 route 分用户认证组、管理员组和 webhook/public 组，不同组的认证/审计规则不同。见 [`server/router.go:127-132`](../../backend/internal/server/router.go#L127) 的注册汇总，以及 [`routes/payment.go:27`](../../backend/internal/server/routes/payment.go#L27)。

## 8. Context 数据传递和依赖原则

### 8.1 两种 context

Gin middleware 同时使用：

- `*gin.Context`：Gin handler chain 的状态、route params、response 和 abort；
- `c.Request.Context()`：向 service/repository 传递 cancellation、request ID、user ID、group、platform、session binding 等跨层信息。

若替换 request context，必须基于当前 context 派生：

```go
ctx := context.WithValue(c.Request.Context(), key, value)
c.Request = c.Request.WithContext(ctx)
```

不要用 `context.Background()` 覆盖 inbound request context，否则超时/客户端取消和上游 tracing 会断开。也不要将 `gin.Context` 直接传入 service/repository。

### 8.2 已有主体 helper

认证相关值写入和读取 helper 在：

- [`auth_subject.go`](../../backend/internal/server/middleware/auth_subject.go)：用户主体及 role；
- [`middleware.go`](../../backend/internal/server/middleware/middleware.go)：API key、subscription、force platform、group assignment 和标准错误 writer；
- [`api_key_auth.go`](../../backend/internal/server/middleware/api_key_auth.go)：`GetAPIKeyFromContext`、`GetSubscriptionFromContext` 和只供 Ops 错误日志的 fallback key。

fallback API key **不是已通过认证的标志**。它专门让认证中途拒绝时 Ops logger 仍能关联用户/组/平台，不能被授权 middleware 当成成功身份。

### 8.3 注入依赖

带依赖的长期使用 middleware 通常用 constructor 返回命名函数类型，放入 [`internal/server/middleware/wire.go`](../../backend/internal/server/middleware/wire.go#L21)，由 `server.ProvideRouter` 收到后交给 routes。Route-specific、无需独立依赖对象的 middleware 可由 route 注册函数创建。

建议：

- 认证/授权、全局安全策略、可复用的主体解析放 `server/middleware`；
- endpoint 语义的协议适配放 routes/对应 handler；
- 使用方定义小 interface，避免测试必须构造整套巨大 service；
- 依赖数据库/Redis 的处理不在 middleware 里直接手写 SQL；
- 避免构造函数中的隐式全局状态；有全局 recorder 时要说明生命周期和测试隔离。

## 9. 新增 middleware 的开发流程

1. **先定位层级**：这是所有请求都需执行、某一 route group、单一协议入口，还是限流/存储基础设施？
2. **写清安全语义**：运行前提（是否需 JWT/API key）、放行/拒绝条件、HTTP status、协议错误结构、是否 fail-open/close。
3. **选定注册位置**：在 `ProvideRouter`、`SetupRouter`、routes group 或单 route 注册；保持明确 scope。
4. **遵守顺序依赖**：如依赖 user context 必须在 auth 后；审计挂载若在 auth 后，则失败认证请求不会走该 audit；模型白名单必须在 Composite 改写前；body 解析必须在 endpoint handler 前且读后回填。
5. **复用规范 helper**：安全 IP、AuthSubject、response envelope、body parser、request ID、audit API 等，不重复解析凭证/转发头。
6. **明确短路处理**：每个拒绝路径写出恰当错误、`Abort()`/return；不要在响应已提交后继续写第二个 envelope。
7. **检查性能和失败策略**：热路径不要无意地每请求加载大配置或打 DB；Redis 错误采用有意识的 fail-open/close，并记录适当日志。
8. **处理敏感信息**：不记录原始 Authorization/API key/密码/body；使用已有脱敏和 audit helpers。
9. **测试中间件本身和挂载位置**：构造 Gin engine 测试允许/拒绝、顺序、response 和 context；再加 route-level 测试验证每条入口确实挂载了 middleware。
10. **验证目标**：运行 `go test ./internal/server/middleware/...`、`go test ./internal/server/routes/...` 及涉及的 handler/service 包；必要时跑集成测试。

### 测试清单

- 正常请求是否到达 handler，handler 是否看到预期 context；
- 缺少凭证、格式错误、过期、撤销、disabled、越权和依赖错误分别返回什么；
- `c.Abort()` 后 handler 是否确实没有执行；
- request body 预读后 handler 是否仍能读取原始完整 payload；
- 多个 middleware 组合时执行顺序是否符合安全设计；
- 反向代理、IPv4/IPv6、缺失/伪造转发头的客户端 IP 结果；
- Redis 故障时 fail-open/close 行为；
- CORS preflight、流式响应、WebSocket upgrade 和 client disconnect；
- 日志/audit 是否脱敏，是否会把凭据写入 Gin error 或 ops event；
- route test 是否覆盖所有协议别名和未经保护的旁路。

`server/middleware` 下已有对应测试，例如 [`jwt_auth_test.go`](../../backend/internal/server/middleware/jwt_auth_test.go)、[`api_key_auth_test.go`](../../backend/internal/server/middleware/api_key_auth_test.go)、[`audit_log_test.go`](../../backend/internal/server/middleware/audit_log_test.go)、[`group_model_allowlist_test.go`](../../backend/internal/server/middleware/group_model_allowlist_test.go)、[`panel_rate_limit_test.go`](../../backend/internal/server/middleware/panel_rate_limit_test.go)、[`session_binding_test.go`](../../backend/internal/server/middleware/session_binding_test.go) 和 [`step_up_test.go`](../../backend/internal/server/middleware/step_up_test.go)。

## 10. 文件地图与职责速查

以下列出 `internal/server/middleware` 中主要实现文件（测试文件不重复列出）。行号链接定位到关键构造函数或实现入口。

| 文件 | 主要作用 |
| --- | --- |
| [`wire.go:21`](../../backend/internal/server/middleware/wire.go#L21) | 为 JWT、Optional JWT、Admin、API key、Audit、Step-up 构造函数提供 Wire provider set；不包括全部无依赖的 route helper。 |
| [`recovery.go:19`](../../backend/internal/server/middleware/recovery.go#L19) | panic 恢复和统一内部错误响应。 |
| [`request_logger.go:17`](../../backend/internal/server/middleware/request_logger.go#L17) | server request ID 和请求级 logger。 |
| [`session_binding.go:18`](../../backend/internal/server/middleware/session_binding.go#L18) | 客户端 IP/UA 安全快照、JWT session binding 验证辅助。 |
| [`logger.go:14`](../../backend/internal/server/middleware/logger.go#L14) | HTTP access log 和 ingress reject 观测。 |
| [`cors.go:16`](../../backend/internal/server/middleware/cors.go#L16) | Origin、预检和 CORS response headers。 |
| [`security_headers.go:111`](../../backend/internal/server/middleware/security_headers.go#L111) | 基线安全头、CSP、nonce、frame-src 动态扩展。 |
| [`server_timing.go:29`](../../backend/internal/server/middleware/server_timing.go#L29) | UI scope 性能计时采集和响应 header。 |
| [`jwt_auth.go:14`](../../backend/internal/server/middleware/jwt_auth.go#L14) | 严格 JWT 用户认证。 |
| [`optional_jwt_auth.go:16`](../../backend/internal/server/middleware/optional_jwt_auth.go#L16) | 匿名或严格 JWT 的可选认证。 |
| [`admin_auth.go:16`](../../backend/internal/server/middleware/admin_auth.go#L16) | 管理员 JWT、legacy/scoped admin key 和 admin WebSocket JWT 认证。 |
| [`api_key_auth.go:21`](../../backend/internal/server/middleware/api_key_auth.go#L21) | 普通 gateway key 认证、账户/分组/IP/部分计费和 context。 |
| [`api_key_auth_google.go:25`](../../backend/internal/server/middleware/api_key_auth_google.go#L25) | Google Gemini 原生格式的 API-key 认证错误适配。 |
| [`step_up.go:48`](../../backend/internal/server/middleware/step_up.go#L48) | 敏感操作 TOTP step-up grant 门控及 handler helper。 |
| [`admin_only.go:11`](../../backend/internal/server/middleware/admin_only.go#L11) | 从已建立的 context role 检查 admin；本身不认证凭证。 |
| [`admin_compliance.go:12`](../../backend/internal/server/middleware/admin_compliance.go#L12) | 管理员合规确认门控。 |
| [`backend_mode_guard.go:14`](../../backend/internal/server/middleware/backend_mode_guard.go#L14) | backend mode 下用户 self-service 禁止策略；文件内另有认证路径 guard。 |
| [`panel_rate_limit.go:44`](../../backend/internal/server/middleware/panel_rate_limit.go#L44) | 面板用户、受限 admin key、公开 IP 的 Redis 限流包装。 |
| [`audit_log.go:166`](../../backend/internal/server/middleware/audit_log.go#L166) | 管理/用户操作审计、凭证和请求字段脱敏。 |
| [`ingress_reject.go:76`](../../backend/internal/server/middleware/ingress_reject.go#L76) | ingress 拒绝原因、无效认证 abuse 保护和 ops recorder。 |
| [`ingress_reject_access_sampler.go`](../../backend/internal/server/middleware/ingress_reject_access_sampler.go) | 对高频预期拒绝的 access log 做常量内存固定窗口采样。 |
| [`group_model_allowlist.go:32`](../../backend/internal/server/middleware/group_model_allowlist.go#L32) | 按 group allowlist 检查请求模型、解析/回填 body、协议化拒绝。 |
| [`middleware.go:36`](../../backend/internal/server/middleware/middleware.go#L36) | force-platform/context helper、错误 envelope writer、ungrouped key gate。 |
| [`request_body_limit.go:10`](../../backend/internal/server/middleware/request_body_limit.go#L10) | route 级 request body max bytes。 |
| [`client_request_id.go:19`](../../backend/internal/server/middleware/client_request_id.go#L19) | Gateway client correlation ID。 |
| [`request_metadata.go:15`](../../backend/internal/server/middleware/request_metadata.go#L15) | request ID、UA 等持久化 metadata 的长度/UTF-8 规范化。 |
| [`auth_subject.go:12`](../../backend/internal/server/middleware/auth_subject.go#L12) | 认证主体和 role 的 context 读取 helper。 |
| [`internal/middleware/rate_limiter.go:70`](../../backend/internal/middleware/rate_limiter.go#L70) | 可配置 fail-open/close 的通用 Redis 固定窗口 rate limiter，不属于 server middleware package。 |
| [`routes/auth.go:16`](../../backend/internal/server/routes/auth.go#L16) | auth route 的 backend guard、audit 和 endpoint 级限流挂载。 |
| [`routes/user.go:12`](../../backend/internal/server/routes/user.go#L12) | 用户 API 的 JWT、backend-mode、panel rate limit、audit 挂载。 |
| [`routes/admin.go:14`](../../backend/internal/server/routes/admin.go#L14) | admin group 的认证、限流、审计、合规和 scoped-key 资源门控。 |
| [`routes/gateway.go:181`](../../backend/internal/server/routes/gateway.go#L181) | `/v1` gateway middleware 顺序；[`gateway.go:339`](../../backend/internal/server/routes/gateway.go#L339) Gemini chain。 |

## 11. 相关源文件行号索引

| 文件/行 | 如何使用 |
| --- | --- |
| [`internal/server/http.go:30`](../../backend/internal/server/http.go#L30) | Gin engine 构造和 Recovery 注册。 |
| [`internal/server/http.go:93`](../../backend/internal/server/http.go#L93) | `configureTrustedProxies`。 |
| [`internal/server/http.go:113`](../../backend/internal/server/http.go#L113) | HTTP server、body size wrapper、h2c。 |
| [`internal/server/router.go:23`](../../backend/internal/server/router.go#L23) | Router 中间件和设置回调的装配入口。 |
| [`internal/server/router.go:99`](../../backend/internal/server/router.go#L99) | 注册 common、API、gateway、payment 和 page routes。 |
| [`server/middleware/jwt_auth.go:14`](../../backend/internal/server/middleware/jwt_auth.go#L14) | JWT Auth constructor。 |
| [`server/middleware/api_key_auth.go:21`](../../backend/internal/server/middleware/api_key_auth.go#L21) | 通用 API-key Auth constructor。 |
| [`server/middleware/audit_log.go:166`](../../backend/internal/server/middleware/audit_log.go#L166) | Audit middleware constructor。 |
| [`server/middleware/step_up.go:48`](../../backend/internal/server/middleware/step_up.go#L48) | Step-up middleware constructor。 |
| [`server/middleware/panel_rate_limit.go:44`](../../backend/internal/server/middleware/panel_rate_limit.go#L44) | Panel limiter 构造入口。 |

行号随源码修改可能变化。可在仓库根目录核对当前行号：

```bash
nl -ba backend/internal/server/router.go | sed -n '45,140p'
nl -ba backend/internal/server/routes/gateway.go | sed -n '175,195p'
rg -n 'func NewJWTAuthMiddleware|func GroupModelAllowlist' backend/internal/server/middleware
```

