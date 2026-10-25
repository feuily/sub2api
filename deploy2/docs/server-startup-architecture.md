# `backend/cmd/server` 启动流程与架构导读

本文以当前仓库实现为准，沿着 `backend/cmd/server` 从进程入口、首次安装分流、配置加载、依赖注入、数据库初始化、路由装配、后台任务启动到优雅关闭完整追踪。目标读者是准备理解项目、排查启动问题，或新增后端模块/功能的开发者。

> 本文是源码导航，不替代接口契约、模块内 README 或具体功能文档。配置项、依赖关系和服务清理责任可能随代码演进；最终以链接到的当前源码为准。

配置文件来源、env 覆盖、代码默认值及 JWT bootstrap 配置流程另见[配置加载与默认值解析](./server-config-loading.md)。

新增一个上游平台需要登记和扩展的后端/前端文件，以及协议、账号生命周期和额度能力检查，见[新增平台接入指南](./adding-platform.md)。

## 1. 一句话理解

服务启动不是在 `main.go` 中手工 `new` 所有对象，而是：

1. `main.go` 负责启动模式选择和进程生命周期；
2. Google Wire 根据 provider set 在编译期生成依赖初始化代码；
3. `config` 提供配置，`repository` 提供数据库/缓存和持久化适配，`service` 承载业务能力，`handler` 将业务转换为 HTTP 入口；
4. `server` 使用 Gin、中间件和 routes 构建 HTTP handler，再包进标准库 `http.Server`；
5. `cmd/server/wire.go` 声明应用级资源清理，`main.go` 接收信号并分阶段关停。

启动链条可以概括为：

```text
Go runtime
  └─ package init: embedded VERSION -> Version
      └─ main
          ├─ bootstrap logger
          ├─ parse --version / --setup
          ├─ NeedsSetup?
          │   ├─ AUTO_SETUP -> env-driven installation -> normal startup
          │   └─ otherwise -> lightweight setup HTTP server -> exit
          └─ runMainServer
              ├─ LoadForBootstrap (读取配置，用于日志/RunMode)
              ├─ initializeApplication (Wire-generated DI graph)
              │   ├─ config provider
              │   ├─ Ent + PostgreSQL migrations
              │   ├─ SQL DB / Redis / repositories
              │   ├─ services and background workers
              │   ├─ handlers and middleware
              │   └─ Gin router -> net/http.Server
              ├─ start PluginManager / PromptAudit
              ├─ ListenAndServe
              ├─ wait SIGINT/SIGTERM
              ├─ HTTP Shutdown (5 seconds)
              └─ deferred Application.Cleanup (10-second cleanup context)
```

## 2. `cmd/server` 文件和边界

| 文件 | 职责 | 修改原则 |
| --- | --- | --- |
| [`main.go`](../../backend/cmd/server/main.go) | 进程入口、flags、安装模式分支、HTTP 主服务启动、信号处理。 | 保持流程编排薄；业务功能不要堆在 `main`。 |
| [`wire.go`](../../backend/cmd/server/wire.go) | Wire injector 声明、`Application` 结构、跨模块 adapter/provider、全应用 cleanup。 | 新增依赖入口或长生命周期服务时检查这里的 provider/cleanup。 |
| [`wire_gen.go`](../../backend/cmd/server/wire_gen.go) | Wire 根据 `wire.go` 生成的依赖构造代码。 | **不要手动编辑**；运行 generate 更新。 |
| [`VERSION`](../../backend/cmd/server/VERSION) | 二进制内嵌默认版本。 | 发布版可由 linker flags 覆盖。 |
| [`wire_gen_test.go`](../../backend/cmd/server/wire_gen_test.go) | 生成注入代码周边行为的测试。 | 仅在相应逻辑变化时更新/补测试。 |

`main.go` 里 `Version`、`Commit`、`Date`、`BuildType` 是构建元数据。`Version` 优先使用 linker 注入值，否则来自 `go:embed VERSION`；`Commit`/`Date` 默认 `unknown`，`BuildType` 默认 `source`。后端 [`Makefile`](../../backend/Makefile) 的 `build` target 注入版本 linker flags。

## 3. 进程入口逐步解析

### 3.1 包初始化和 bootstrap logger

Go 先运行 package 初始化逻辑：

- `VERSION` 通过 `//go:embed VERSION` 编译进二进制。
- `init()` 只在 `Version` 没有被 linker flags 设置时，才将内嵌版本写入 `Version`；空值回退到 `0.0.0-dev`。
- 导入 `_ "github.com/Wei-Shaw/sub2api/ent/runtime"` 触发 Ent runtime 注册逻辑，不是“空导入无作用”。

进入 `main()` 后先调用 `logger.InitBootstrap()`，并注册 `defer logger.Sync()`。此时完整应用配置和配置化 logger 尚未装配，bootstrap logger 用于早期启动、配置错误、安装流程和 Wire 错误等日志。

### 3.2 flags 优先级

当前入口只定义两个应用 flag：

```text
--version  显示版本信息并退出
--setup    在终端运行 CLI 安装向导
```

处理顺序：

1. `--version` 优先：打印版本/commit/build time 后 return，不检查安装状态，不连接数据库，也不启动 Wire graph。
2. `--setup`：调用 `setup.RunCLI()` 后 return。它面向安装向导，不是运行中的 Web 服务控制命令。
3. 未指定这两个选项：检查 `setup.NeedsSetup()`，再走自动安装、Web 安装页或正式服务。

### 3.3 首次安装检测

`setup.NeedsSetup()` 会先检查 `SKIP_SETUP`。值是 `true`、`1`、`yes` 时跳过首次安装判断；否则根据 `DATA_DIR` 对应的 `config.yaml` 和 `.installed` lock 文件判断是否需要 setup。

尚未安装时：

- `AUTO_SETUP=true|1|yes`：`AutoSetupFromEnv()` 从 `DATABASE_*`、`REDIS_*`、`ADMIN_*`、`SERVER_*`、`JWT_SECRET`、时区等环境变量构造 setup 配置，检查 PostgreSQL/Redis、初始化迁移、创建适用的首位管理员、写配置和安装锁。成功后继续正常启动。
- 未启用自动安装：运行 `runSetupServer()`，正式服务 Wire graph 不会创建。

`SKIP_SETUP` 只绕过安装检测，不会初始化配置、验证数据库或代替迁移流程。生产环境不要为了掩盖缺少配置而开启它。

### 3.4 轻量 Web 安装服务

`runSetupServer()` 单独构建一个轻量 Gin engine：

- `gin.New()` 创建 router；
- 装配 Recovery、基础 CORS、CSP/Security Headers；
- `setup.RegisterRoutes` 注册 setup API；
- 若有嵌入式前端则接入 frontend middleware；
- `config.GetServerAddress()` 确定监听地址；
- 创建标准库 `http.Server`，设置 ReadHeaderTimeout、IdleTimeout，并启用 HTTP/1.1 与明文 HTTP/2 (h2c) protocols；
- 调用 `ListenAndServe()` 提供安装页。

这个安装 server 不经过正式 `initializeApplication`，不会创建主业务 handlers、repository 和后台服务。安装完成后通常需要结束此 setup 进程并按正常部署方式重新启动，正式服务才会加载新配置。

## 4. 正式启动 `runMainServer()`

### 4.1 配置加载与日志切换

入口先调用 `config.LoadForBootstrap()`。配置包的 loader：

- 搜索名为 `config` 的 YAML 配置；
- 加载默认值；
- 启用 Viper 环境变量映射（点号转换为下划线），并处理 `TZ`、`ENABLE_SERVER_TIMING` 等显式环境映射；
- 反序列化到 `config.Config`，归一化/兼容部分旧配置，再执行配置校验；
- Bootstrap 模式允许启动阶段 JWT secret 暂时为空，以便后续安装/secret 初始化流程处理。

然后 `logger.Init(logger.OptionsFromConfig(cfg.Log))` 用完整配置切换日志设置。日志初始化失败会让服务退出。若 `RunMode` 是 `simple`，入口明确记录提示：此模式会关闭 billing 和 quota 检查；这属于业务模式而不是普通性能开关。

注意：正式启动里配置在入口先加载一次，随后 Wire 的 `config.ProvideConfig()` 又调用 `LoadForBootstrap()` 为 DI 图提供 `*config.Config`。这两个加载结果分别供启动编排与注入图使用；改配置加载方式时要考虑两处调用保持一致。

### 4.2 BuildInfo 注入

入口把版本与构建类型封装为 `handler.BuildInfo`，传入 `initializeApplication(buildInfo)`。`wire.go` 中：

- `provideServiceBuildInfo` 转成 `service.BuildInfo`，供更新/系统信息等服务使用；
- `providePluginHostInfo` 转成 `service.PluginHostInfo`，供本地插件宿主识别当前宿主版本。

这类小型转换 provider 也是 adapter：在模块间传递所需信息时，不让服务反向依赖 `cmd/server` 包。

### 4.3 Wire 构图和错误边界

`initializeApplication` 使用 `wire.Build(...)` 声明入口集合。Wire 是**编译期依赖注入代码生成器**，不是运行时反射容器：

- 它根据 provider 参数类型建立依赖有向图；
- 找不到 provider、产生歧义或依赖环通常会在生成/编译阶段报错；
- `wire_gen.go` 展开成普通 Go 函数调用，启动时按拓扑顺序构造对象；
- provider 可返回 error；初始化失败沿生成函数返回至 `runMainServer()`，启动阶段用 `log.Fatalf` 终止，不会伪装成“服务已启动”。

实际 provider 顺序请阅读当前 [`wire_gen.go`](../../backend/cmd/server/wire_gen.go)；不要依赖 provider set 列表的文本顺序作为生命周期契约。

## 5. 依赖模块和数据流

下面按职责解释 Wire 汇总的 provider set。并非每次 HTTP 请求都会触及所有模块；依赖图初始化时会构造可达服务，服务 provider 可能同时启动后台 worker。

### 5.1 `internal/config`：配置源和校验

- [`config/wire.go`](../../backend/internal/config/wire.go)：暴露 `ProvideConfig`。
- [`config/config.go`](../../backend/internal/config/config.go)：`Config` 及 server/database/redis/security/gateway/billing/OAuth 等配置结构、默认值、Viper 环境变量加载和校验。
- 配置通过依赖注入传给 repositories/services/handlers/server，避免每个模块自行读取环境变量。
- 新配置优先进入语义归属清晰的配置结构，添加 `mapstructure` key、默认/校验/环境变量映射（如有）及配置测试；不要散落使用 `os.Getenv`。

### 5.2 `ent` 与 `internal/repository`：持久化和基础设施适配

`repository.ProviderSet` 大致提供：

- Ent repositories：用户、API key、组、账号、代理、订阅、用量、运维、支付、审计、定时任务等数据访问对象；
- Redis caches：API key、billing、gateway、scheduler、session、rate limit、quota、token 等缓存/协调能力；
- 基础客户端：Ent、SQL DB、Redis；
- 外部 HTTP client、验证码 client、OAuth client、价格/发布信息 client、图片对象存储等适配器；
- 加密器、备份工具等基础设施实现。

`repository.InitEnt(cfg)` 建立 PostgreSQL 连接、应用连接池配置、获取迁移锁并应用内嵌 migrations，再创建 Ent client。临时不可用数据库错误会按限定策略重试；迁移/配置等永久错误会返回失败。`ProvideSQLDB` 从 Ent driver 取得同一连接池的 `*sql.DB`，供需要原生 SQL 的 repository 使用。

Redis 通过 `InitRedis(cfg)` 创建 go-redis client，读取地址、凭据、DB、TLS、pool 和 timeout 配置。创建 client 本身不等同于启动时成功完成一次 Redis ping；真正访问时由服务操作触发连接。不要在 DI 之外另建孤立 Redis client。

**Repository 边界**：处理 Ent/SQL/Redis/外部 SDK 等存储或协议细节，向上提供清晰的数据访问接口；不承担 HTTP 状态码和业务流程决策。跨 repository 的业务事务通常由 service 编排。

### 5.3 `internal/service`：业务编排和领域行为

服务 provider set 规模较大，包含的能力大致有：

- 身份认证、用户/API key、组/账号/代理、订阅和计费；
- gateway 调度、平台兼容、OAuth 与 token refresh、并发控制；
- 用量/计费记录、价格、限额、quota、缓存失效；
- 运维观测、审计、日志聚合、定期清理、告警；
- 邮件、支付、促销/affiliate；
- batch image、插件、内容审核、幂等和系统操作锁；
- 定时任务、过期处理、上游探测/额度同步。

Service 是主要业务入口：组合 repository、其他 services 和外部 port；对 handler 暴露领域操作；不要让 handler 直接拼复杂 SQL 或让 repository 决定 HTTP 语义。

一些 provider 不只是 `NewXxx(...)`，还会执行 `Start()` 并启动 goroutine/cron/订阅者。因此“Wire 构造对象”可能具有生命周期副作用。新增后台任务前先查其 provider 实现，明确启动时机、失败策略和关闭方法。

### 5.4 `internal/securityaudit`：安全审计/提示审核模块

Provider set 通过接口绑定组合：

- PostgreSQL repository 实现 Job/Event repository；
- Redis 实现 payload store；
- scanner 实现 prompt scanner；
- ConfigManager 实现 config store；
- PromptService 实现 prompt engine 与管理接口；
- Coordinator 协调网关请求路径的审核逻辑；
- PromptAdminHandler 提供管理 API。

正式服务构造 `Application` 时暴露 `PromptAudit`，但真正 `Start()` 在 `runMainServer()` 中调用；启动失败按代码说明以 degraded 状态记录，主服务继续运行（具体拒绝/降级行为取决于已持久化策略和模块实现）。

### 5.5 `internal/payment`：支付领域和加密能力

支付 provider set 负责 encryption key、provider registry、default load balancer，并通过 `wire.Bind` 将具体 load balancer 实现绑定至抽象接口。加密密钥校验失败会作为初始化错误传播；缺省密钥则部分加密/签名能力不可用并给出 warning。业务支付配置是否启用仍由服务配置决定。

### 5.6 `internal/server/middleware`：跨请求策略

Wire 提供的 middleware 包括 JWT、可选 JWT、管理员权限、API key、审计日志、step-up authentication 等。它们组合在 router 的路由组上，不等同于业务 service。全局 middleware 还由 `SetupRouter` 按顺序安装。

注意 middleware 顺序会影响安全边界、request context、日志和 CORS 行为；更改时检查路由测试和相关 middleware 测试。

### 5.7 `internal/handler`：传输层适配

Handler 接收 Gin context/HTTP 输入，校验传输格式，调用 service，输出 HTTP status/JSON/stream。Provider set 中既有顶级 handlers、gateway handlers，也有 `handler/admin` 下的管理端 handlers。`ProvideHandlers` 将它们聚合成 `handler.Handlers`，router 对该统一结构注册路由。

推荐方向：

```text
HTTP request -> middleware -> handler -> service -> repository/port -> DB/Redis/upstream
HTTP response <- middleware <- handler <- service result/error
```

业务规则放在 service，数据持久化放在 repository；不要让 service 依赖 Gin。

### 5.8 `internal/server`：Router 和 HTTP server

`server.ProviderSet` 提供 `ProvideRouter`、`ProvideHTTPServer`：

- `ProvideRouter` 按 `server.mode` 设 Gin release/debug mode，创建 `gin.New()`，配置 trusted proxies；
- 构造 websearch manager 的配置变更 builder；
- 调用 `SetupRouter` 组装路由；
- `ProvideHTTPServer` 根据 server config 设置监听地址、请求头限制、header/idle timeout；
- 按 body size 配置包装 `http.MaxBytesHandler`；
- 可选配置 h2c HTTP/2；刻意不设置会截断长流式响应的 `WriteTimeout`。

路由组织主要位于 [`server/routes/`](../../backend/internal/server/routes/)：

- common routes（health/status 等）；
- `/api/v1` 用户、认证、管理、支付等业务 API；
- 根级 gateway routes（兼容客户端协议）；
- 页面/定价数据路由。

新增 handler 并不代表 HTTP endpoint 自动生效；必须同时把 handler 注入、加入 `Handlers` 汇总（如适用）并由相应 routes 注册。

## 6. Router 装配和请求生命周期

### 6.1 正式全局中间件顺序

`SetupRouter()` 注册全局中间件（顺序有意义），大体包括：

1. RequestLogger：请求级日志/请求观测；
2. SessionBindingContext：将安全解析的客户端 IP、User-Agent 等写入 request context；
3. Logger：请求日志；
4. CORS；
5. SecurityHeaders/CSP：动态读取缓存中的 frame origins；
6. ServerTiming：按配置暴露性能计时；
7. 若前端 embed 可用则服务嵌入前端，注册 setting 更新 callback 使 HTML cache/CSP frame origins 刷新；
8. 注册 common、API、gateway、payment、page routes。

Router 构造期间会从 setting service 刷新 frame-src origins；失败时保留已有缓存，避免因瞬时错误错误清空 CSP。

### 6.2 路由上的身份和权限

通用 API 位于 `/api/v1`，其下再根据 endpoint 使用 JWT、可选 JWT、管理员、审计、step-up 和限流策略。Gateway API 使用 API key middleware，并可能依赖订阅、API key、运维审计、设置和 composite 路由解析器。

新增 endpoint 时必须明确：

- 是否匿名、JWT、API key 或管理员认证；
- 是否需要 step-up / audit / rate limiter；
- 错误响应格式及请求体上限；
- 是否支持流式响应、长连接、请求取消；
- 用户数据的对象级授权和日志脱敏要求。

## 7. 后台服务启动与关闭

### 7.1 Provider 构造时可能启动的 worker

例如当前 `service/wire.go` 中可以看到若干 provider 创建后立即调用 `Start()`，包括 ops collector/aggregation/alert/cleanup、audit log、批量图像清理、token refresh、定时测试 runner、订阅/账号清理等。API key auth cache invalidator provider 还会启动 Pub/Sub subscriber。

因此 DI 初始化期间有些操作会：

- 启动 goroutine、ticker、cron 或 Redis subscription；
- 读取数据库/Redis；
- 注册全局回调或替换 runtime manager；
- 在构造阶段出现初始化错误。

新增服务不要把“构造对象”和“开始不可逆外部动作”混为一谈，先参照相邻服务的 provider 生命周期约定。对需要 `Stop`/`Close` 的服务，必须确保其关闭可幂等、可超时且错误可观测。

### 7.2 明确在 `runMainServer()` 启动的服务

在 `initializeApplication()` 返回后，入口单独执行：

- `PluginManager.Start(context.Background())`：启动失败记录 degraded state，应用继续运行；
- `PromptAudit.Start(context.Background())`：启动失败记录 degraded state；模块策略决定审核功能状态。

这些启动点在 HTTP server `ListenAndServe()` 之前，适合需要显式处理启动失败的 app-level runtime；不要仅因新服务要“开机运行”就擅自将其放到 handler 请求里启动。

### 7.3 关停顺序

`runMainServer()`：

1. 在 goroutine 中运行 `ListenAndServe()`；
2. 主 goroutine 等待 `SIGINT` 或 `SIGTERM`；
3. 使用 5 秒 context 调 `http.Server.Shutdown()`，优雅结束接收请求；
4. 函数退出时触发 `defer app.Cleanup()`。

`provideCleanup()` 为应用层服务创建清理步骤，大部分后台服务/worker 并行停止；之后按顺序关闭基础设施（Redis、Ent/数据库连接等）。它创建一个 10 秒 context 并传给 PromptAudit shutdown，但其他 `Stop()` 调用不接收该 context，WaitGroup 也会等待所有并行步骤结束；因此这个 10 秒值**不是整个 cleanup 的硬性执行上限**。结束后代码才检查 context 是否已超时并记录日志。具体完整名单和某服务的清理方式以 [`wire.go`](../../backend/cmd/server/wire.go) 为准。

当前 cleanup 列表是显式维护的，不会自动发现所有实现了 `Stop()` 的服务。新增有生命周期的依赖时，如果没有挂入 cleanup，就可能在关停时遗留 goroutine、Redis subscriber、连接或 flush 队列。若某个停止动作必须受限于关机 deadline，应让其 API 接受 context 并在实现中遵守取消，而不是只依赖外层 timeout。

## 8. 目录地图：新增功能从哪里开始

`backend/internal` 采用职责拆分，不是每个领域都只放在一个目录里：

| 目录 | 主要职责 | 常见开发入口 |
| --- | --- | --- |
| [`cmd/`](../../backend/cmd/) | 可执行程序入口，例如 server 和运维 CLI。 | 仅新增独立进程命令时改。 |
| [`config/`](../../backend/internal/config/) | 配置结构、默认值、加载、归一化、校验。 | 新配置项。 |
| [`domain/`](../../backend/internal/domain/) | 领域类型/规则的共享表达（按具体包查看）。 | 稳定领域概念，避免放 HTTP 类型。 |
| [`model/`](../../backend/internal/model/) | 应用/持久化相关模型结构（以具体 package 定义为准）。 | 数据结构或模型映射。 |
| [`repository/`](../../backend/internal/repository/) | Ent/SQL/Redis 和外部接口适配器、repository 实现。 | 查询、事务、缓存、第三方 client。 |
| [`service/`](../../backend/internal/service/) | 业务服务、工作流、策略、缓存协作。 | 业务规则、调度、用量计费。 |
| [`handler/`](../../backend/internal/handler/) | HTTP transport handlers、DTO；`admin/` 放管理端 handler。 | 新 API 的 HTTP 层。 |
| [`server/`](../../backend/internal/server/) | Router、routes、中间件和 HTTP server 构造。 | 路由装配/HTTP 层策略。 |
| [`payment/`](../../backend/internal/payment/) | 支付领域接口、provider registry/load balancer 等。 | 支付子系统扩展。 |
| [`securityaudit/`](../../backend/internal/securityaudit/) | Prompt/security audit 模块。 | 安全审核规则和运行时。 |
| [`platform/`](../../backend/internal/platform/) | 平台相关能力划分（按具体包查看）。 | 上游平台特有的公共能力。 |
| [`pkg/`](../../backend/internal/pkg/) | 可复用的技术/协议包。 | 真正跨业务复用的工具或协议实现。 |
| [`setup/`](../../backend/internal/setup/) | CLI/Web/自动安装和初始化逻辑。 | 首次安装流程。 |
| [`web/`](../../backend/internal/web/) | 前端 embed、静态资源服务等。 | 前端打包/托管行为。 |
| [`middleware/`](../../backend/internal/middleware/) | 其他通用 middleware（与 `server/middleware` 按归属区分）。 | 先搜索相邻实现，避免重复造中间件。 |
| [`integration/`](../../backend/internal/integration/) | 集成/e2e 测试。 | 跨模块、真实基础设施行为测试。 |
| [`testutil/`](../../backend/internal/testutil/) | 测试辅助设施。 | 共用测试 setup。 |
| [`util/`](../../backend/internal/util/) | 通用小工具。 | 仅当确为通用而非业务策略时。 |

目录角色是导航，不代表 package 一定满足某种抽象。新增代码前先搜索同领域既有接口、测试和 provider。

## 9. 采用的设计方法/模式

以下是从当前代码可观察到的实践；不是要求所有新代码机械套用模式名称。

### 9.1 依赖注入与编译期组合（Wire）

Provider 用构造函数参数声明依赖，Wire 在编译时组图。优点是初始化依赖可追踪、接口绑定显式、缺失依赖尽早发现；缺点是 provider set 和生成文件都需维护，过大的构造函数也会暴露模块耦合。

新 provider 必须保持依赖方向清晰，避免 service import handler/server/cmd。

### 9.2 Repository + Service 分层

- Repository 隐藏数据库、缓存或外部协议细节；
- Service 负责业务规则、跨仓储协调、事务语义和策略；
- Handler 负责协议适配与 HTTP 响应。

通常先在 service 定义需要的接口，再由 repository 提供实现；如果代码中已有接口位置/命名约定，以附近实现为准。

### 9.3 Ports & Adapters / 依赖倒置

不少 service 依赖抽象接口，repository 或特定 package 提供实现，Wire 用 `wire.Bind` 绑定，例如 payment LoadBalancer、securityaudit repository/store/scanner。外部系统 client 通常通过 interface/factory 注入，便于测试替换和演进。

接口应由使用方所需能力塑形，避免创建“万能 client/repository”接口。

### 9.4 Adapter / Provider 函数

`ProvideAuthService`、`ProvideGatewayHandler` 一类 provider 在保持旧构造 API 的同时注入额外能力、设置可选依赖或启动服务。`provideServiceBuildInfo` 是类型转换 adapter。新增必要依赖时，如果不适合改变公开构造函数，可参考相邻 provider 的方式，但不要用 setter 隐藏关键依赖而不补测试。

### 9.5 Middleware Chain + Route Group

跨请求逻辑通过 Gin middleware chain，身份/权限和审计策略按 route group 应用。顺序和 scope 决定安全边界；新路由不仅要“能访问”，还要验证错误路径、匿名访问和权限不足。

### 9.6 Strategy / Factory / Runtime reconfiguration

代码中存在按配置选择策略、构造外部 client、动态 manager 更新的模式，例如图片对象存储 factory、websearch manager builder、连接/协议策略。若配置能在线更新，选择可重建的 factory/manager，而不是让启动时捕获一份永远不刷新的值；同时明确并发切换与旧资源关闭。

### 9.7 Worker 生命周期与 Outbox

后台服务通常有显式 `Start`/`Stop`；跨实例事件/缓存失效场景可用数据库 outbox、Redis Pub/Sub 或分布式锁，而不应只依赖进程内 goroutine。选择方案要考虑重复投递、丢失、重试、leader 选举和关机 flush。

### 9.8 Fail-fast 与 Degraded Mode

关键依赖或非法配置在 provider 返回 error 时阻止启动；可选能力可以 warning + degraded mode，让非相关 API 继续运行。新增模块必须明确属于哪种：

- **必需模块**：初始化失败应阻止服务接流量；
- **可选模块**：明确不可用范围、健康/告警状态和恢复路径；
- **请求级失败**：由 service/handler 用项目统一错误模型返回。

不要吞错、返回空成功结构，或只打印日志却让依赖方误以为模块可用。

## 10. 新增模块或功能的推荐步骤

### 场景 A：新增一个普通业务 API

1. **澄清领域规则**：确认行为、状态变更、事务边界、幂等、授权和错误语义。
2. **定义数据模型/迁移**：如需 schema 变更，在 `backend/migrations/` 增加迁移并写迁移测试；检查 Ent schema/代码生成要求，按 Makefile/生成说明更新生成物。
3. **实现 repository**：优先复用现有 Ent client、事务和缓存模式；定义最小需要的方法，处理 not found/并发冲突。
4. **实现 service**：编排业务、授权关联检查、事务和副作用；可注入接口以便单测。
5. **实现 DTO/handler**：限制输入、避免把数据库模型直接暴露为 API 契约；使用统一错误响应和日志脱敏。
6. **接入 Wire**：将 repository constructor 加入 `repository.ProviderSet`；service 加入 `service.ProviderSet`；handler 加入 `handler.ProviderSet`；若要聚合进 `Handlers`，更新 `ProvideHandlers` 和结构体。
7. **注册 routes**：在正确 route group 注册并配置身份验证、admin、audit、step-up、限流中间件。
8. **测试**：service 单测；handler 请求/错误/权限测试；route 注册和权限回归测试；必要时 integration 测试。
9. **生成和验证**：在 `backend/` 运行 `go generate ./cmd/server`（按改动还可能需要其他 generate），执行相关 `go test`，最后 `go test ./...` 或项目规定的完整验证。
10. **审视运行时影响**：新增连接、缓存、后台任务、配置项、指标/日志和关闭行为，更新运维文档。

### 场景 B：新增后台 worker/定时任务

在普通 API 步骤外，重点额外完成：

1. 定义 Start/Stop 语义：Start 是否幂等、启动失败返回什么、Stop 是否等待 goroutine 退出。
2. context/ticker/cron 是否可取消，避免无限存活 goroutine。
3. 多实例是否会重复执行；需要时使用 leader lock、数据库 claim 或其他分布式协调。
4. 设置合理的启动延迟、重试/退避、超时、并发上限和观测指标。
5. 在 provider 中以清晰方式创建/启动（或在 app-level 启动），并把停止动作加入 `cmd/server/wire.go` 的 `provideCleanup`。
6. 明确与 Redis/Ent 关闭顺序：worker 必须先停，所依赖的基础设施最后关闭。
7. 测试重复 Start/Stop、关闭期间任务、上下文取消和依赖故障。

### 场景 C：新增外部平台/上游协议

1. 平台协议解析/转换放入对应 `platform/` 或 `pkg/` 现有结构，避免塞入 `main` 或通用 handler。
2. 外部 HTTP client 作为 interface/adapter 注入，配置代理、TLS、超时、重试及错误分类。
3. service 负责凭据生命周期、账号状态、限流/冷却和 failover 语义。
4. gateway handler/router 仅在协议入口确实不同或兼容层要求时扩展。
5. 增加协议 fixture、错误映射、stream 断开/取消、重试与多平台路由测试。

### 最小化依赖接入示意

下面是说明层次与 Wire 接线关系的伪代码（不是仓库中可直接复制的 API）：

```go
// repository: 持久化实现
type WidgetRepository interface {
    Get(ctx context.Context, id int64) (*Widget, error)
}

type widgetRepository struct { client *ent.Client }
func NewWidgetRepository(client *ent.Client) WidgetRepository {
    return &widgetRepository{client: client}
}

// service: 业务语义，不依赖 Gin/HTTP
type WidgetService struct { repo WidgetRepository }
func NewWidgetService(repo WidgetRepository) *WidgetService {
    return &WidgetService{repo: repo}
}

// handler: HTTP transport adapter
type WidgetHandler struct { service *WidgetService }
func NewWidgetHandler(service *WidgetService) *WidgetHandler {
    return &WidgetHandler{service: service}
}
```

落到本仓库时，还要按 package 内的既有 interface/constructor 约定调整：repository/service/handler 分别进入对应 `ProviderSet`；handler 若由统一 `Handlers` 聚合，就加入其构造 provider 与字段；最后在 route package 绑定 HTTP 方法、路径和 middleware。需要迁移则先实现 schema/migration，再写 repository 测试。不要为了“完整分层”给只有简单内存逻辑的功能硬造 repository、接口或额外抽象。

## 11. 生成代码、构建和测试

在 `backend/` 目录：

```bash
# Wire injector 由 main.go 的 go:generate 声明
go generate ./cmd/server

# 只编译服务命令，验证依赖图与类型
go test ./cmd/server -run '^$'
go build ./cmd/server

# 针对改动包运行测试；例如
go test ./internal/service/...
go test ./internal/handler/...
go test ./internal/server/...

# 项目完整测试/静态检查
make test
```

若 provider 参数变化后 Wire 报错，先处理真实依赖缺口/歧义，再生成；不要通过编辑 `wire_gen.go` 暂时绕过。`wire_gen.go` 在代码评审中应与 `wire.go` 同步，避免只提交生成文件或只提交 injector 改动。

## 12. 启动故障排查顺序

按失败阶段缩小范围，不要一开始就删除 volume 或重置数据库：

1. **二进制/flags**：运行 `--version`，核对 commit/version/build type。
2. **安装分支**：检查 `DATA_DIR`、`config.yaml`、`.installed`、`AUTO_SETUP`、`SKIP_SETUP`；确认没有误指向空数据目录。
3. **配置加载**：检查 YAML 语法、环境变量映射与验证错误；不要打印完整 env。
4. **数据库**：确认 host/port/认证/库名/TLS，检查迁移错误；`InitEnt` 启动时会应用 migrations。
5. **Redis**：确认 address、认证、TLS、DB index、连接池设置；Redis client 创建与 `PING` 成功是两个阶段。
6. **Wire 构造**：找到第一条 provider 初始化错误，不只看最后的 `Failed to initialize application`。
7. **Router/端口**：确认 bind address、端口冲突、trusted proxies、body/header 限制及 health endpoint。
8. **后台模块**：区分 fail-fast error 与 degraded warning；确认后台任务需要的 Redis/外网/密钥配置。
9. **运行期请求**：按 middleware → route → handler → service → repository/上游的方向跟踪 trace/request id。
10. **关闭/重启**：先看收到信号、HTTP Shutdown、Cleanup 日志；worker 卡住时检查 Stop 是否等待和共享资源关闭顺序。

## 13. 代码阅读路径建议

按以下顺序阅读最容易建立整体模型：

1. [`cmd/server/main.go`](../../backend/cmd/server/main.go)：入口决策和生命周期。
2. [`cmd/server/wire.go`](../../backend/cmd/server/wire.go)：应用对象、provider 汇总和 cleanup。
3. [`cmd/server/wire_gen.go`](../../backend/cmd/server/wire_gen.go)：当前真实依赖构造顺序；只读。
4. [`internal/config/config.go`](../../backend/internal/config/config.go)：配置加载、默认、校验。
5. [`internal/repository/ent.go`](../../backend/internal/repository/ent.go) 和 [`internal/repository/redis.go`](../../backend/internal/repository/redis.go)：基础连接和 migration。
6. `internal/{repository,service,handler}/wire.go`：各层 provider graph。
7. [`internal/server/http.go`](../../backend/internal/server/http.go) 与 [`internal/server/router.go`](../../backend/internal/server/router.go)：server、全局 middleware 和路由组。
8. `internal/server/routes/`：具体 route scope、权限和 endpoint 映射。
9. 对目标功能沿 handler → service → repository → model/schema/migration 阅读，再回看测试。

## 14. 本文分析文件与源码行号索引

下表把本文的架构描述映射到可直接跳转的源码位置。行号是当前 checkout 的位置；源码修改后行号可能变化，链接定位的是对应函数/声明的起始行。

### 进程入口、配置和依赖注入

| 文件及行号 | 对应功能 |
| --- | --- |
| [`cmd/server/main.go:29`](../../backend/cmd/server/main.go#L29) | `VERSION` embed 声明；[`main.go:33`](../../backend/cmd/server/main.go#L33) 定义 build metadata；[`main.go:40`](../../backend/cmd/server/main.go#L40) 版本初始化。 |
| [`cmd/server/main.go:55`](../../backend/cmd/server/main.go#L55) | `main()`：bootstrap logger、flag 优先级、setup 判断和正式服务分流。 |
| [`cmd/server/main.go:97`](../../backend/cmd/server/main.go#L97) | `runSetupServer()`：独立安装 HTTP server、setup 路由和基础安全 middleware。 |
| [`cmd/server/main.go:134`](../../backend/cmd/server/main.go#L134) | `runMainServer()`：加载配置、切换 logger、构建应用、启动可选服务、监听信号与 HTTP shutdown。 |
| [`cmd/server/wire.go:27`](../../backend/cmd/server/wire.go#L27) | `Application`：主 HTTP server、PromptAudit、PluginManager 与 Cleanup 的应用级边界。 |
| [`cmd/server/wire.go:34`](../../backend/cmd/server/wire.go#L34) | `initializeApplication()`：Wire 根 injector，汇总各模块 ProviderSet。 |
| [`cmd/server/wire.go:70`](../../backend/cmd/server/wire.go#L70) | build info 到 service 的 adapter；[`wire.go:77`](../../backend/cmd/server/wire.go#L77) 是 plugin host build info adapter。 |
| [`cmd/server/wire.go:84`](../../backend/cmd/server/wire.go#L84) | `provideCleanup()`：后台模块停止和 Redis/Ent 资源关闭。 |
| [`cmd/server/wire_gen.go:35`](../../backend/cmd/server/wire_gen.go#L35) | Wire 生成的 `initializeApplication()` 实际依赖构造顺序；只读、不可手改。 |
| [`cmd/server/wire_gen.go:396`](../../backend/cmd/server/wire_gen.go#L396) | Wire 生成的 cleanup 构造实现；源定义仍应修改 `wire.go`。 |
| [`internal/config/config.go:68`](../../backend/internal/config/config.go#L68) | 顶层 `Config` 聚合结构；[`config.go:1823`](../../backend/internal/config/config.go#L1823) `Load()`；[`config.go:1830`](../../backend/internal/config/config.go#L1830) `LoadForBootstrap()`；[`config.go:1834`](../../backend/internal/config/config.go#L1834) Viper load 流程。 |
| [`internal/config/wire.go:6`](../../backend/internal/config/wire.go#L6) | Config ProviderSet；[`config/wire.go:11`](../../backend/internal/config/wire.go#L11) 为 Wire 提供 bootstrap config。 |
| [`internal/setup/setup.go:47`](../../backend/internal/setup/setup.go#L47) | 数据目录和配置/lock 文件定位；[`setup.go:165`](../../backend/internal/setup/setup.go#L165) 判断是否首次安装。 |
| [`internal/setup/setup.go:216`](../../backend/internal/setup/setup.go#L216) | PostgreSQL 安装连接检查；[`setup.go:281`](../../backend/internal/setup/setup.go#L281) Redis 安装连接检查；[`setup.go:314`](../../backend/internal/setup/setup.go#L314) 安装、迁移、管理员和配置落盘。 |
| [`internal/setup/setup.go:592`](../../backend/internal/setup/setup.go#L592) | 自动安装开关；[`setup.go:617`](../../backend/internal/setup/setup.go#L617) 从环境变量自动安装。 |
| [`internal/setup/cli.go:43`](../../backend/internal/setup/cli.go#L43) | 交互式终端安装向导。 |

### 数据、业务模块和 HTTP 装配

| 文件及行号 | 对应功能 |
| --- | --- |
| [`internal/repository/wire.go:67`](../../backend/internal/repository/wire.go#L67) | Repository ProviderSet：数据库 repositories、Redis caches、外部 client 和基础设施 provider 清单。 |
| [`internal/repository/wire.go:185`](../../backend/internal/repository/wire.go#L185) | Ent provider；[`wire.go:211`](../../backend/internal/repository/wire.go#L211) 从 Ent driver 暴露 SQL DB；[`wire.go:234`](../../backend/internal/repository/wire.go#L234) 创建 Redis client。 |
| [`internal/repository/ent.go:33`](../../backend/internal/repository/ent.go#L33) | 仅对暂时性 PostgreSQL 初始化错误重试；[`ent.go:104`](../../backend/internal/repository/ent.go#L104) 初始化 Ent、迁移和 DB client。 |
| [`internal/repository/redis.go:23`](../../backend/internal/repository/redis.go#L23) | Redis client 创建；[`redis.go:33`](../../backend/internal/repository/redis.go#L33) 按 config 构造连接池/TLS/timeout 参数。 |
| [`internal/repository/migrations_runner.go:114`](../../backend/internal/repository/migrations_runner.go#L114) | 迁移入口；[`migrations_runner.go:139`](../../backend/internal/repository/migrations_runner.go#L139) 执行嵌入式迁移。 |
| [`migrations/migrations.go:33`](../../backend/migrations/migrations.go#L33) | `//go:embed *.sql` 将迁移 SQL 编译进程序。 |
| [`internal/service/wire.go:31`](../../backend/internal/service/wire.go#L31) | `BuildInfo`；[`service/wire.go:58`](../../backend/internal/service/wire.go#L58) AuthService provider；[`service/wire.go:122`](../../backend/internal/service/wire.go#L122) TokenRefresh provider。 |
| [`internal/service/wire.go:179`](../../backend/internal/service/wire.go#L179) | PluginManager provider；[`service/wire.go:526`](../../backend/internal/service/wire.go#L526) OpsMetrics worker provider；[`service/wire.go:572`](../../backend/internal/service/wire.go#L572) OpsCleanup provider；[`service/wire.go:598`](../../backend/internal/service/wire.go#L598) AuditLog provider。 |
| [`internal/service/wire.go:859`](../../backend/internal/service/wire.go#L859) | Service ProviderSet 总表；阅读具体 provider 时还应检查该函数是否调用 Start 或注册 callback。 |
| [`internal/payment/wire.go:22`](../../backend/internal/payment/wire.go#L22) | 支付加密 key 校验/提供；[`payment/wire.go:60`](../../backend/internal/payment/wire.go#L60) payment ProviderSet 与接口绑定。 |
| [`internal/securityaudit/prompt_module.go:5`](../../backend/internal/securityaudit/prompt_module.go#L5) | Prompt audit ProviderSet 和接口绑定；[`securityaudit/coordinator.go:25`](../../backend/internal/securityaudit/coordinator.go#L25) Coordinator；[`securityaudit/prompt_service.go:35`](../../backend/internal/securityaudit/prompt_service.go#L35) PromptService。 |
| [`internal/handler/wire.go:13`](../../backend/internal/handler/wire.go#L13) | AdminHandlers 聚合；[`handler/wire.go:99`](../../backend/internal/handler/wire.go#L99) GatewayHandler provider；[`handler/wire.go:126`](../../backend/internal/handler/wire.go#L126) OpenAI Gateway handler provider；[`handler/wire.go:183`](../../backend/internal/handler/wire.go#L183) Handlers 聚合结构构造；[`handler/wire.go:235`](../../backend/internal/handler/wire.go#L235) Handler ProviderSet。 |
| [`internal/server/middleware/wire.go:21`](../../backend/internal/server/middleware/wire.go#L21) | Middleware ProviderSet；具体 JWT / admin / API-key 实现分别见 [`jwt_auth.go:14`](../../backend/internal/server/middleware/jwt_auth.go#L14)、[`admin_auth.go:16`](../../backend/internal/server/middleware/admin_auth.go#L16)、[`api_key_auth.go:21`](../../backend/internal/server/middleware/api_key_auth.go#L21)。 |
| [`internal/server/http.go:24`](../../backend/internal/server/http.go#L24) | Server ProviderSet；[`http.go:30`](../../backend/internal/server/http.go#L30) Router provider；[`http.go:93`](../../backend/internal/server/http.go#L93) trusted proxies；[`http.go:113`](../../backend/internal/server/http.go#L113) 标准库 HTTP server 和协议配置。 |
| [`internal/server/router.go:23`](../../backend/internal/server/router.go#L23) | 全局 middleware、前端和动态设置回调装配；[`router.go:99`](../../backend/internal/server/router.go#L99) common/API/gateway/payment 路由注册汇总。 |
| [`internal/server/routes/common.go:10`](../../backend/internal/server/routes/common.go#L10) | 通用 health/status 路由。 |
| [`internal/server/routes/auth.go:16`](../../backend/internal/server/routes/auth.go#L16) | 认证路由；[`routes/user.go:12`](../../backend/internal/server/routes/user.go#L12) 用户路由；[`routes/admin.go:14`](../../backend/internal/server/routes/admin.go#L14) 管理路由。 |
| [`internal/server/routes/gateway.go:22`](../../backend/internal/server/routes/gateway.go#L22) | 外部模型 API/gateway 路由；[`routes/payment.go:27`](../../backend/internal/server/routes/payment.go#L27) 用户及管理支付路由。 |
| [`internal/web/embed_on.go:48`](../../backend/internal/web/embed_on.go#L48) | Embed 前端构造与配置注入；[`embed_on.go:303`](../../backend/internal/web/embed_on.go#L303) legacy embedded frontend middleware。 |

### 逐行查看命令

在仓库根目录可以用以下方式核对上下文（将路径/行号替换为上表目标）：

```bash
nl -ba backend/cmd/server/main.go | sed -n '50,165p'
nl -ba backend/cmd/server/wire.go | sed -n '20,115p'
nl -ba backend/internal/server/router.go | sed -n '20,145p'
```

`nl -ba` 的左侧数字就是本文引用的源文件行号。查找当前变动后的定义，也可在根目录使用 `rg -n 'func Name|var ProviderSet' backend/internal/...`。

## 15. 常见误区

- 把 `wire_gen.go` 当成手写业务实现；它是生成代码。
- 把 `ProviderSet` 中的顺序当成启动顺序；实际图由 Wire 依赖决定。
- 在 service/repository 中直接引入 Gin context；会让业务层耦合传输框架。
- 只写 handler 不注册 route，或只注册 route 不添加 middleware/权限测试。
- 新建后台 goroutine，却没有 context cancel/Stop/cleanup 挂接。
- 认为构造 Redis client 就证明 Redis 已连通；它通常是惰性连接。
- 认为本地缺失 `config.yaml` 就一定是首次安装；`DATA_DIR`、`.installed` 和 `SKIP_SETUP` 会改变判断。
- 启动时每个模块私自读环境变量或创建重复连接池；这会使配置来源不一致、资源难以关闭。
- 在迁移或启动失败时删除生产数据卷；应先确认配置路径、备份、迁移状态和容器项目。
